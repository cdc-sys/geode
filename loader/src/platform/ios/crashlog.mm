// this is mostly copied from macos
#include <crashlog.hpp>

#include <Geode/utils/string.hpp>
#include <array>
#include <thread>
#include <execinfo.h>
#include <dlfcn.h>
#include <cxxabi.h>
#include <algorithm>

#include <mach-o/dyld_images.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#include <fcntl.h>
#import <Foundation/Foundation.h>

using namespace geode::prelude;

// https://gist.github.com/jvranish/4441299

static constexpr size_t FRAME_SIZE = 128;
static int s_signal = 0;
static siginfo_t* s_siginfo = nullptr;
static ucontext_t* s_context = nullptr;
static size_t s_backtraceSize = 0;
static std::array<void*, FRAME_SIZE> s_backtrace;
static std::vector<struct dyld_image_info const*> s_images;
static int s_pipe[2];

static std::string_view getSignalCodeString() {
    switch(s_signal) {
        case SIGSEGV: return "SIGSEGV: Segmentation Fault";
        case SIGINT: return "SIGINT: Interactive attention signal, (usually ctrl+c)";
        case SIGFPE:
            switch(s_siginfo->si_code) {
                case FPE_INTDIV: return "SIGFPE: (integer divide by zero)";
                case FPE_INTOVF: return "SIGFPE: (integer overflow)";
                case FPE_FLTDIV: return "SIGFPE: (floating-point divide by zero)";
                case FPE_FLTOVF: return "SIGFPE: (floating-point overflow)";
                case FPE_FLTUND: return "SIGFPE: (floating-point underflow)";
                case FPE_FLTRES: return "SIGFPE: (floating-point inexact result)";
                case FPE_FLTINV: return "SIGFPE: (floating-point invalid operation)";
                case FPE_FLTSUB: return "SIGFPE: (subscript out of range)";
                default: return "SIGFPE: Arithmetic Exception";
            }
        case SIGILL:
            switch(s_siginfo->si_code) {
                case ILL_ILLOPC: return "SIGILL: (illegal opcode)";
                case ILL_ILLOPN: return "SIGILL: (illegal operand)";
                case ILL_ILLADR: return "SIGILL: (illegal addressing mode)";
                case ILL_ILLTRP: return "SIGILL: (illegal trap)";
                case ILL_PRVOPC: return "SIGILL: (privileged opcode)";
                case ILL_PRVREG: return "SIGILL: (privileged register)";
                case ILL_COPROC: return "SIGILL: (coprocessor error)";
                case ILL_BADSTK: return "SIGILL: (internal stack error)";
                default: return "SIGILL: Illegal Instruction";
            }
        case SIGTERM: return "SIGTERM: a termination request was sent to the program";
        case SIGABRT: return "SIGABRT: usually caused by an abort() or assert()";
        case SIGBUS: return "SIGBUS: Bus error (bad memory access)";
        default: return "Unknown signal code";
    }
}

static std::string getImageName(struct dyld_image_info const* image) {
    if (image == nullptr) {
        return "<Unknown>";
    }
    std::string imageName = image->imageFilePath;
    if (imageName.empty()) {
        imageName = "<Unknown>";
    }

    // don't print those really long paths
    if (
        imageName.ends_with("Geode.ios.dylib")
        || imageName.ends_with("GeometryJump")
        || imageName.find("game/geode/unzipped") != std::string::npos
    ) {
        imageName = imageName.substr(imageName.find_last_of('/') + 1);
    }

    return imageName;
}

// https://stackoverflow.com/questions/28846503/getting-sizeofimage-and-entrypoint-of-dylib-module
size_t getImageSize(struct mach_header_64 const* header) {
    if (header == nullptr) {
        return 0;
    }
    size_t sz = 0;

    auto lc = (struct load_command const*) (header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        auto seg = (struct segment_command_64 const*) lc;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(seg->segname, SEG_PAGEZERO) != 0) {
            sz += seg->vmsize; // Size of segments
        }
        lc = (struct load_command const*) ((char *) lc + lc->cmdsize);
    }
    return sz;
}

static std::vector<struct dyld_image_info const*> getAllImages() {
    std::vector<struct dyld_image_info const*> images;
    struct task_dyld_info dyldInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count) == KERN_SUCCESS) {
        struct dyld_all_image_infos* imageInfos = (struct dyld_all_image_infos*)dyldInfo.all_image_info_addr;

        for (size_t i = 0; i < imageInfos->infoArrayCount; ++i) {
            images.push_back(&imageInfos->infoArray[i]);
        }
    }

    return images;
}

static struct dyld_image_info const* imageFromAddress(void const* addr) {
    if (addr == nullptr) {
        return nullptr;
    }

    auto iter = std::upper_bound(s_images.begin(), s_images.end(), addr, [](auto const addr, auto const image) {
        return (uintptr_t)addr < (uintptr_t)image->imageLoadAddress;
    });

    if (iter == s_images.begin()) {
        return nullptr;
    }
    --iter;

    auto image = *iter;
    auto imageSize = getImageSize((struct mach_header_64 const*)image->imageLoadAddress);
    auto imageAddress = (uintptr_t)image->imageLoadAddress;
    if ((uintptr_t)addr >= imageAddress && (uintptr_t)addr < imageAddress + imageSize) {
        return image;
    }
    return nullptr;
}

static Mod* modFromAddress(void const* addr) {
    if (addr == nullptr) {
        return nullptr;
    }
    auto image = imageFromAddress(addr);
    if (image == nullptr) {
        return nullptr;
    }

    std::filesystem::path imagePath = getImageName(image);
    if (!std::filesystem::exists(imagePath)) {
        return nullptr;
    }
    auto geodePath = dirs::getGeodeDir() / "Geode.ios.dylib";
    if (imagePath.filename() == geodePath.filename()) {
        return Mod::get();
    }

    for (auto& mod : Loader::get()->getAllMods()) {
        if (!mod->isEnabled() || !std::filesystem::exists(mod->getBinaryPath())) {
            continue;
        }
        if (std::filesystem::equivalent(imagePath, mod->getBinaryPath())) {
            return mod;
        }
    }
    return nullptr;
}

// Formats a memory address into something that can more precisely point its location,
// i.e. 0x12345678 -> "0x12345678 (GeometryDash + 0x5678)"
static std::string formatAddress(void const* addr) {
    auto image = imageFromAddress(addr);
    
    if (image) {
        auto imageName = getImageName(image);
        return fmt::format(
            "{} ({} + {})",
            addr,
            imageName,
            reinterpret_cast<void const*>((uintptr_t)addr - (uintptr_t)image->imageLoadAddress)
        );
    } else {
        return fmt::format("{}", addr);
    }
}

static std::string getInfo(void* address, Mod* faultyMod) {
    std::stringstream stream;
    auto image = imageFromAddress(address);
    auto imageName = getImageName(image);
    stream << "Faulty Lib: " << imageName << "\n";
    stream << "Instruction Address: " << formatAddress(address) << "\n";
    stream << fmt::format("Signal Code: 0x{:x} ({})\n", s_signal, getSignalCodeString());

    // these 5 have the si_addr field available as per `man sigaction`
    if (s_signal == SIGILL || s_signal == SIGFPE || s_signal == SIGSEGV || s_signal == SIGBUS || s_signal == SIGTRAP) {
        stream << "Signal Detail: ";

        switch (s_signal) {
            case SIGILL: {
                stream << fmt::format("Illegal instruction was encountered at {}", formatAddress(s_siginfo->si_addr));
            } break;

            case SIGFPE: {
                stream << fmt::format("Floating point exception was thrown at {}", formatAddress(s_siginfo->si_addr));
            } break;

            case SIGSEGV: {
                stream << fmt::format("Could not access memory at {} (", formatAddress(s_siginfo->si_addr));
                
                switch (s_siginfo->si_code) {
                    case SEGV_MAPERR: {
                        stream << "address not mapped to an object";
                    } break;

                    case SEGV_ACCERR: {
                        stream << "invalid permissions for mapped object";
                    } break;
                }

                stream << ")";
            } break;

            case SIGBUS: {
                stream << fmt::format("Bus error when trying to access memory at {} (", formatAddress(s_siginfo->si_addr));

                switch (s_siginfo->si_code) {
                    case BUS_ADRALN: {
                        stream << "invalid address alignment";
                    } break;

                    case BUS_ADRERR: {
                        stream << "nonexistent physical address";
                    } break;

                    case BUS_OBJERR: {
                        stream << "object-specific hardware error";
                    } break;
                }

                stream << ")";
            } break;

            case SIGTRAP: {
                stream << fmt::format("Breakpoint was hit at {}", formatAddress(s_siginfo->si_addr));
            } break;
        }

        stream << "\n";
    }

    return stream.str();
}

extern "C" void signalHandler(int signal, siginfo_t* signalInfo, void* vcontext) {
    /*auto context = reinterpret_cast<ucontext_t*>(vcontext);
    s_backtraceSize = backtrace(s_backtrace.data(), FRAME_SIZE);

    // for some reason this is needed, dont ask me why
    s_backtrace[2] = reinterpret_cast<void*>(context->uc_mcontext->__ss.__pc);
    if (s_backtraceSize < FRAME_SIZE) {
        s_backtrace[s_backtraceSize] = nullptr;
    }*/

    s_signal = signal;
    s_siginfo = signalInfo;
    s_context = reinterpret_cast<ucontext_t*>(vcontext);
    char buf = '1';
    write(s_pipe[1], &buf, 1);
}

// https://stackoverflow.com/questions/8278691/how-to-fix-backtrace-line-number-error-in-c
std::string executeCommand(std::string const& cmd) {
    std::stringstream stream;
    std::array<char, 1024> buf;

    if (FILE* ptr = popen(cmd.c_str(), "r")) {
        while (fgets( buf.data(), buf.size(), ptr ) != NULL) {
            stream << buf.data();
        }
        pclose(ptr);
    }

    return stream.str();
}

std::string addr2Line() {
    std::stringstream stream;
    stream << "atos -p " << getpid() << " ";
    for (int i = 1; i < s_backtraceSize; ++i) {
        stream << s_backtrace[i] << " ";
    }
    // std::cout << "command: " << stream.str() << std::endl;
    return executeCommand(stream.str());
}

static std::string getStacktrace() {
    std::stringstream stacktrace;

    auto messages = backtrace_symbols(s_backtrace.data(), s_backtraceSize);
    if (s_backtraceSize < FRAME_SIZE) {
        messages[s_backtraceSize] = nullptr;
    }

    std::stringstream lines(addr2Line());

    for (int i = 0; i < s_backtraceSize; ++i) {
        int index;
        std::string binary;
        uintptr_t address;
        std::string function;
        uintptr_t offset;
        std::string line;
        size_t cutoff;

        auto message = std::string(i == 0 ? "" : messages[i]);
        auto stream = std::stringstream(message);

        if (i > 0) {
            stream >> index;

            if (!lines.eof()) {
                std::getline(lines, line);
            }
            std::getline(stream, binary);
            cutoff = binary.find("0x");
            stream = std::stringstream(binary.substr(cutoff));
            binary = geode::utils::string::trim(binary.substr(0, cutoff));
            stream >> std::hex >> address >> std::dec;
        } else {
            // first entry in the stacktrace, not present in `messages`
            address = (uintptr_t) s_backtrace[0];
            index = 0;
        }

        if (!line.empty()) {
            // log::debug("address: {}", address);
            auto image = imageFromAddress(reinterpret_cast<void*>(address));
            // log::debug("image: {}", image);
            stacktrace << " - " << std::showbase << std::hex;

            if (image) {
                auto baseAddress = image->imageLoadAddress;
                auto imageName = getImageName(image);
                stacktrace << imageName << " + " << (address - (uintptr_t)baseAddress);
            }
            else {
                stacktrace << address;
            }
            stacktrace << std::dec;
            stacktrace << ": " << line << "\n";
        }
        else {
            if (i > 0) {
                std::getline(stream, function);

                cutoff = function.find("+");
                stream = std::stringstream(function.substr(cutoff + 1));
                stream >> offset;
                function = geode::utils::string::trim(function.substr(0, cutoff));

                {
                    int status;
                    auto demangle = abi::__cxa_demangle(function.c_str(), 0, 0, &status);
                    if (status == 0) {
                        function = demangle;
                    }
                    free(demangle);
                }
            }

            // don't display the (function + offset) part if it will be bogus.
            // the first case (0x0) happens with hook handlers, while the second happens because
            // GD exports a few fmt symbols, so backtrace_symbols thinks every function in GD is the last fmt symbol in the binary
            if (function == "0x0" || (binary == "GeometryJump" && offset > 0x1000)) {
                function = "";
            }

            if (auto image = imageFromAddress(reinterpret_cast<void*>(address))) {
                stacktrace << "- " << getImageName(image) << " + " << std::showbase << std::hex << (address - (uintptr_t)image->imageLoadAddress) << std::dec;
            }
            else {
                stacktrace << "- " << binary;
            }

            if (!function.empty()) {
                stacktrace << " (" << function << " + " << offset << ")";
            }

            stacktrace << " @ " << std::showbase << std::hex << address << std::dec << "\n";
        }
    }

    free(messages);

    return stacktrace.str();
}

static std::string getRegisters() {
    std::stringstream registers;

    auto context = s_context;
    auto& ss = context->uc_mcontext->__ss;

    // geez
    registers << std::showbase << std::hex /*<< std::setfill('0') << std::setw(16) */;
    registers << "x0: " << ss.__x[0] << "\n";
    registers << "x1: " << ss.__x[1] << "\n";
    registers << "x2: " << ss.__x[2] << "\n";
    registers << "x3: " << ss.__x[3] << "\n";
    registers << "x4: " << ss.__x[4] << "\n";
    registers << "x5: " << ss.__x[5] << "\n";
    registers << "x6: " << ss.__x[6] << "\n";
    registers << "x7: " << ss.__x[7] << "\n";
    registers << "x8: " << ss.__x[8] << "\n";
    registers << "x9: " << ss.__x[9] << "\n";
    registers << "x10: " << ss.__x[10] << "\n";
    registers << "x11: " << ss.__x[11] << "\n";
    registers << "x12: " << ss.__x[12] << "\n";
    registers << "x13: " << ss.__x[13] << "\n";
    registers << "x14: " << ss.__x[14] << "\n";
    registers << "x15: " << ss.__x[15] << "\n";
    registers << "x16: " << ss.__x[16] << "\n";
    registers << "x17: " << ss.__x[17] << "\n";
    registers << "x18: " << ss.__x[18] << "\n";
    registers << "x19: " << ss.__x[19] << "\n";
    registers << "x20: " << ss.__x[20] << "\n";
    registers << "x21: " << ss.__x[21] << "\n";
    registers << "x22: " << ss.__x[22] << "\n";
    registers << "x23: " << ss.__x[23] << "\n";
    registers << "x24: " << ss.__x[24] << "\n";
    registers << "x25: " << ss.__x[25] << "\n";
    registers << "x26: " << ss.__x[26] << "\n";
    registers << "x27: " << ss.__x[27] << "\n";
    registers << "x28: " << ss.__x[28] << "\n";
    registers << "fp: " << ss.__fp << "\n";
    registers << "lr: " << ss.__lr << "\n";
    registers << "sp: " << ss.__sp << "\n";
    registers << "pc: " << ss.__pc << "\n";
    registers << "cpsr: " << ss.__cpsr << "\n";

    return registers.str();
}

static void handlerThread() {
    // no more mutex deadlocker
    char buf;
    while (read(s_pipe[0], &buf, 1) != 0) {
        auto signalAddress = reinterpret_cast<void*>(s_context->uc_mcontext->__ss.__pc);
        // as you can tell, i moved code from signalHandler to here
        if (s_context) {
            //s_backtraceSize = backtrace(s_backtrace.data(), FRAME_SIZE);
            // i can't use 2 because then it'll show the actual stacktrace to be lower than what it actually is
            s_backtrace[s_backtraceSize++] = signalAddress;
            void* current_fp = reinterpret_cast<void*>(s_context->uc_mcontext->__ss.__fp);
            /*
            if (s_backtraceSize < FRAME_SIZE) {
                s_backtrace[s_backtraceSize] = nullptr;
            }
            */
            while (s_backtraceSize < FRAME_SIZE && current_fp) {
                void** frame = reinterpret_cast<void**>(current_fp);
                void* next_fp = frame[0];
                void* lr = frame[1];

                if (next_fp == current_fp || lr == nullptr) break;

                s_backtrace[s_backtraceSize++] = lr;
                current_fp = next_fp;
            }
        }

        s_images = getAllImages(); // load them once
        std::sort(s_images.begin(), s_images.end(), [](auto const a, auto const b) {
            return (uintptr_t)a->imageLoadAddress < (uintptr_t)b->imageLoadAddress;
        });

        Mod* faultyMod = modFromAddress(signalAddress);

        // Mod* faultyMod = nullptr;
        // for (int i = 1; i < s_backtraceSize; ++i) {
        //     auto mod = modFromAddress(s_backtrace[i]);
        //     if (mod != nullptr) {
        //         faultyMod = mod;
        //         break;
        //     }
        // }
        auto text = crashlog::writeCrashlog(faultyMod, getInfo(signalAddress, faultyMod), getStacktrace(), getRegisters());

        log::error("Geode crashed!\n{}", text);
        std::_Exit(EXIT_FAILURE);
        //s_signal = 0;
    }
}

static bool s_lastLaunchCrashed;

bool crashlog::setupPlatformHandler() {
    // for whatever reason, i can't just do int*
    if (pipe(s_pipe) != 0) return false;
    fcntl(s_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(s_pipe[1], F_SETFD, FD_CLOEXEC);
    struct sigaction action;
    action.sa_sigaction = &signalHandler;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, nullptr);
    // I'd rather not track interrupt lol
    // sigaction(SIGINT, &action, nullptr);
    sigaction(SIGFPE, &action, nullptr);
    sigaction(SIGILL, &action, nullptr);
    sigaction(SIGTERM, &action, nullptr);
    sigaction(SIGABRT, &action, nullptr);
    sigaction(SIGBUS, &action, nullptr);

    std::thread(&handlerThread).detach();

    auto lastCrashedFile = crashlog::getCrashLogDirectory() / "last-crashed";
    if (std::filesystem::exists(lastCrashedFile)) {
        s_lastLaunchCrashed = true;
        std::filesystem::remove(lastCrashedFile);
    }
    return true;
}

void crashlog::setupPlatformHandlerPost() {}

bool crashlog::didLastLaunchCrash() {
    return s_lastLaunchCrashed;
}

std::filesystem::path crashlog::getCrashLogDirectory() {
    return dirs::getGeodeDir() / "crashlogs";
}
