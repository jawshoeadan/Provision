module app;

import core.sys.posix.sys.time;
import std.algorithm;
import std.array;
import std.base64;
import std.datetime.stopwatch: StopWatch;
import file = std.file;
import std.format;
import std.getopt;
import std.math;
import std.mmfile;
import std.net.curl;
import std.parallelism;
import std.path;
import std.range;
import std.stdio;
import std.zip;

import provision;
import provision.androidlibrary;
import provision.symbols;

import constants;

version (X86_64) {
    enum string architectureIdentifier = "x86_64";
} else version (X86) {
    enum string architectureIdentifier = "x86";
} else version (AArch64) {
    enum string architectureIdentifier = "arm64-v8a";
} else version (ARM) {
    enum string architectureIdentifier = "armeabi-v7a";
} else {
    static assert(false, "Architecture not supported :(");
}

struct AnisetteCassetteHeader {
  align(1):
    ubyte[7] magicHeader = [0x69, 'C', 'A', 'S', 'S', 'T', 'E'];
    ubyte formatVersion = 0;
    ulong baseTime;

    ubyte[64] machineId;
}

static assert(AnisetteCassetteHeader.sizeof % 16 == 0);

__gshared ulong origTime;
int main(string[] args) {
    writeln(mkcassetteBranding, " v", provisionVersion);

    char[] identifier = cast(char[]) "ba10defe42ea69ff";
    string configurationPath = expandTilde("~/.config/Provision");
    string outputFile = "./otp-file.acs";
    ulong days = 90;
    bool onlyInit = false;
    bool apkDownloadAllowed = true;

    // Parse command-line arguments
    auto helpInformation = getopt(
        args,
        "i|identifier", format!"The identifier used for the cassette (default: %s)"(identifier), &identifier,
        "a|adi-path", format!"Where the provisioning information should be stored on the computer (default: %s)"(configurationPath), &configurationPath,
        "d|days", format!"Number of days in the cassette (default: %s)"(days), &days,
        "o|output", format!"Output location (default: %s)"(outputFile), &outputFile,
        "init-only", format!"Download libraries and exit (default: %s)"(onlyInit), &onlyInit,
        "can-download", format!"If turned on, may download the dependencies automatically (default: %s)"(apkDownloadAllowed), &apkDownloadAllowed,
    );

    if (helpInformation.helpWanted) {
        defaultGetoptPrinter("This program allows you to host anisette through libprovision!", helpInformation.options);
        return 0;
    }

    if (!file.exists(configurationPath)) {
        file.mkdirRecurse(configurationPath);
    }

    string libraryPath = configurationPath.buildPath("lib/" ~ architectureIdentifier);

    auto coreADIPath = libraryPath.buildPath("libCoreADI.so");
    auto SSCPath = libraryPath.buildPath("libstoreservicescore.so");

    // Download APK if needed
    if (!(file.exists(coreADIPath) && file.exists(SSCPath)) && apkDownloadAllowed) {
        auto http = HTTP();
        http.onProgress = (size_t dlTotal, size_t dlNow, size_t ulTotal, size_t ulNow) {
            write("Downloading libraries from Apple servers... ");
            if (dlTotal != 0) {
                write((dlNow * 100)/dlTotal, "%     \r");
            } else {
                // Convert dlNow (in bytes) to a human readable string
                float downloadedSize = dlNow;

                enum units = ["B", "kB", "MB", "GB", "TB"];
                int i = 0;
                while (downloadedSize > 1000 && i < units.length - 1) {
                    downloadedSize = floor(downloadedSize) / 1000;
                    ++i;
                }

                write(downloadedSize, units[i], "     \r");
            }
            return 0;
        };
        auto apkData = get!(HTTP, ubyte)(nativesUrl, http);
        writeln("Downloading libraries from Apple servers... done!     \r");
        auto apk = new ZipArchive(apkData);
        auto dir = apk.directory();

        if (!file.exists(libraryPath)) {
            file.mkdirRecurse(libraryPath);
        }
        file.write(coreADIPath, apk.expand(dir["lib/" ~ architectureIdentifier ~ "/libCoreADI.so"]));
        file.write(SSCPath, apk.expand(dir["lib/" ~ architectureIdentifier ~ "/libstoreservicescore.so"]));
    }

    if (onlyInit) {
        return 0;
    }

    // 1 per minute
    auto numberOfOTP = days*24*60;

    ubyte[] mid;
    ubyte[] nothing;

    // We store the real time in a shared variable, and create a thread-local time variable.
    __gshared timeval origTimeVal;
    gettimeofday(&origTimeVal, null);
    origTime = origTimeVal.tv_sec;
    targetTime = taskPool.workerLocalStorage(origTimeVal);

    // Initializing ADI and machine if it has not already been made.
    Device device = new Device(configurationPath.buildPath("/dev/null"));
    {
        ADI adi = new ADI("lib/" ~ architectureIdentifier);
        adi.provisioningPath = configurationPath;

        if (!device.initialized) {
            stderr.write("Creating machine... ");

            import std.digest;
            import std.digest.sha;
            import std.random;
            import std.range;
            import std.uni;
            import std.uuid;
            device.serverFriendlyDescription = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
            device.uniqueDeviceIdentifier = randomUUID().toString().toUpper();
            device.adiIdentifier = sha1Of(device.uniqueDeviceIdentifier).toHexString()[0..16].toLower();
            device.localUserUUID = sha256Of(device.uniqueDeviceIdentifier).toHexString().toUpper();

            stderr.writeln("done !");
        }

        adi.identifier = device.adiIdentifier;

        ProvisioningSession provisioningSession = new ProvisioningSession(adi, device);
        provisioningSession.provision(-2);

        mid = adi.requestOTP(-2).machineIdentifier;
    }

    auto adi = taskPool().workerLocalStorage!ADI({
        // We hook the gettimeofday function in the library to change the date.
        AndroidLibrary storeServicesCore = new AndroidLibrary(SSCPath, [
            "gettimeofday": cast(void*) &gettimeofday_timeTravel
        ]);

        ADI adi = new ADI(libraryPath, storeServicesCore);

        adi.provisioningPath = configurationPath;
        adi.identifier = device.adiIdentifier;

        return adi;
    }());

    StopWatch sw;
    writeln("Starting generation of ", numberOfOTP, " otps (", days, " days) with ", totalCPUs, " threads.");
    sw.start();

    auto anisetteCassetteHeader = AnisetteCassetteHeader();
    anisetteCassetteHeader.baseTime = origTime;
    anisetteCassetteHeader.machineId[0..mid.length] = mid;

    auto anisetteCassetteHeaderBytes = (cast(ubyte*) &anisetteCassetteHeader)[0..AnisetteCassetteHeader.sizeof];

    // The file consists of 1 header and then all the 16-bytes long OTPs, so we make a memory-mapped file of the correct size.
    scope otpFile = new MmFile(outputFile, MmFile.Mode.readWriteNew, AnisetteCassetteHeader.sizeof + 16 * numberOfOTP * ubyte.sizeof, null);
    scope acs = cast(ubyte[]) otpFile[0..$];
    acs[0..AnisetteCassetteHeader.sizeof] = anisetteCassetteHeaderBytes;

    // we take every 16 bytes chunk of the OTP part of the file, and iterate concurrently through it.
    foreach (idx, otp; parallel(std.range.chunks(cast(ubyte[]) acs[AnisetteCassetteHeader.sizeof..$], 16))) {
        scope localAdi = adi.get();
        scope time = targetTime.get();

        time.tv_sec = origTime + idx * 30;
        targetTime.get() = time;

        otp[] = localAdi.requestOTP(-2).oneTimePassword[8..24];

        assert(targetTime.get().tv_sec == origTime + idx * 30);
    }

    sw.stop();

    writeln("Success. File written at ", outputFile, ", duration: ", sw.peek());

    return 0;
}

import core.sys.posix.sys.time;
import std.parallelism;

public __gshared TaskPool.WorkerLocalStorage!timeval targetTime;

private extern (C) int gettimeofday_timeTravel(timeval* timeval, void* ptr) {
    *timeval = targetTime.get();
    return 0;
}
