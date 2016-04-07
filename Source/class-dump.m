// -*- mode: ObjC -*-

//  This file is part of class-dump, a utility for examining the Objective-C segment of Mach-O files.
//  Copyright (C) 1997-1998, 2000-2001, 2004-2015 Steve Nygard.

#include <getopt.h>
#include <libgen.h>

#import "CDClassDump.h"
#import "CDFindMethodVisitor.h"
#import "CDMachOFile.h"
#import "CDFatFile.h"
#import "CDFatArch.h"
#import "CDSearchPathState.h"
#import "CDSymbolsGeneratorVisitor.h"
#import "CDCoreDataModelProcessor.h"
#import "CDSymbolMapper.h"
#import "CDSystemProtocolsProcessor.h"
#import "CDdSYMProcessor.h"

NSString *defaultSymbolMappingPath = @"symbols.map";

#define SDK_PATH_BEFORE \
        "/Applications/Xcode.app/Contents/Developer" \
            "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator"
#define SDK_PATH_AFTER ".sdk"
#define SDK_PATH_USAGE_STRING SDK_PATH_BEFORE "<version>" SDK_PATH_AFTER

void print_usage(void)
{
    fprintf(stderr,
            "PreEmptive Protection for iOS - Class Guard, version " CLASS_DUMP_VERSION "\n"
            "\n"
            "Usage:\n"
            "  ios-class-guard --analyze [options] <Mach-O file>\n"
            "  ios-class-guard --obfuscate-sources [options]\n"
            "  ios-class-guard --translate-crashdump [options] <input file> <output file>\n"
            "  ios-class-guard --translate-dsym [options] <input dSYM> <output dSYM>\n"
            "  ios-class-guard --list-arches <Mach-O file>\n"
            "  ios-class-guard --version\n"
            "  ios-class-guard --help\n"
            "\n"
            "Common options:\n"
            "  --symbols-map <symbols.map>  Path to symbol map file\n"
            "\n"
            "Additional options for --analyze:\n"
            "  -F <pattern>                 Filter classes/protocols\n"
            "  -x <pattern>                 Exclude arbitrary symbols\n"
            "  --arch <arch>                Specify architecture from universal binary\n"
            "  --sdk-root <path>            Specify full SDK root path\n"
            "  --sdk-ios <version>          Specify iOS SDK by version\n"
            "  --emit-excludes <file>       Emit computed list of excluded symbols\n"
            "\n"
            "Additional options for --obfuscate-sources:\n"
            "  --storyboards <path>         Alternate path for XIBs and storyboards\n"
            "  --symbols-header <symbols.h> Path to obfuscated symbol header file\n"
            "\n"
            );
}

#define CD_OPT_ARCH        1
#define CD_OPT_LIST_ARCHES 2
#define CD_OPT_VERSION     3
#define CD_OPT_SDK_IOS     4
#define CD_OPT_SDK_ROOT    6
#define CD_OPT_HIDE        7
#define CD_OPT_TRANSLATE_CRASH 10
#define CD_OPT_TRANSLATE_DSYM 11

#define PPIOS_OPT_ANALYZE 12
#define PPIOS_OPT_OBFUSCATE 13
#define PPIOS_OPT_EMIT_SDK_SYMBOLS 14
static char* programName;

static NSString * resolveSDKPath(NSFileManager * fileManager,
                                 NSString * const sdkRootOption,
                                 NSString * const sdkIOSOption);

void reportError(int exitCode, const char* format, ...){
    va_list  args;
    va_start(args, format);
    fprintf(stderr, "%s: ", programName);
    vfprintf(stderr, format, args);
    fprintf(stderr, "\n");
    exit(exitCode);
}

void populateProgramName(char* argv0){
    programName = basename(argv0);
}

void checkSingleMode(BOOL hasMode){
    if(hasMode){
        reportError(2, "Only a single mode of operation is supported at a time");
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSFileManager * fileManager = [NSFileManager defaultManager];
        BOOL shouldAnalyze = NO;
        BOOL shouldObfuscate = NO;
        BOOL shouldListArches = NO;
        BOOL shouldPrintVersion = NO;
        BOOL shouldTranslateDsym = NO;
        BOOL shouldTranslateCrashDump = NO;
        BOOL shouldShowUsage = NO;
        CDArch targetArch;
        BOOL hasSpecifiedArch = NO;
        NSMutableSet *hiddenSections = [NSMutableSet set];
        NSMutableArray *classFilter = [NSMutableArray new];
        NSMutableArray *ignoreSymbols = [NSMutableArray new];
        NSString *xibBaseDirectory = nil;
        NSString *symbolsPath = nil;
        NSString *symbolMappingPath = nil;
        NSString * sdkRootOption = nil;
        NSString * sdkIOSOption = nil;

        int ch;
        BOOL errorFlag = NO;

        struct option longopts[] = {
                { "filter-class",            no_argument,       NULL, 'F' },
                { "exclude-symbols",         required_argument, NULL, 'x' },
                { "storyboards",             required_argument, NULL, 'X' },
                { "symbols-header",          required_argument, NULL, 'O' },
                { "symbols-map",             required_argument, NULL, 'm' },
                { "crash-dump",              required_argument, NULL, 'c' },
                { "arch",                    required_argument, NULL, CD_OPT_ARCH }, //needed?
                { "list-arches",             no_argument,       NULL, CD_OPT_LIST_ARCHES },
                { "emit-sdk-symbols",        required_argument, NULL, PPIOS_OPT_EMIT_SDK_SYMBOLS },
                { "suppress-header",         no_argument,       NULL, 't' },
                { "version",                 no_argument,       NULL, CD_OPT_VERSION },
                { "sdk-ios",                 required_argument, NULL, CD_OPT_SDK_IOS },
                { "sdk-root",                required_argument, NULL, CD_OPT_SDK_ROOT },
                { "hide",                    required_argument, NULL, CD_OPT_HIDE },
                { "analyze",                 no_argument,       NULL, PPIOS_OPT_ANALYZE },
                { "obfuscate-sources",       no_argument,       NULL, PPIOS_OPT_OBFUSCATE },
                { "translate-crashdump",     no_argument,       NULL, CD_OPT_TRANSLATE_CRASH},
                { "translate-dsym",          no_argument,       NULL, CD_OPT_TRANSLATE_DSYM},
                { "help",                    no_argument,       NULL, 'h'},
                { NULL,                      0,                 NULL, 0 },
        };

        populateProgramName(argv[0]);

        if (argc == 1) {
            print_usage();
            exit(0);
        }

        CDClassDump *classDump = [[CDClassDump alloc] init];
        BOOL hasMode = NO;
        while ( (ch = getopt_long(argc, argv, "F:x:th", longopts, NULL)) != -1) {

            switch (ch) {
                case CD_OPT_ARCH: {
                    NSString *name = [NSString stringWithUTF8String:optarg];
                    targetArch = CDArchFromName(name);
                    if (targetArch.cputype != CPU_TYPE_ANY)
                        hasSpecifiedArch = YES;
                    else {
                        fprintf(stderr, "Error: Unknown arch %s\n\n", optarg);
                        errorFlag = YES;
                    }
                    break;
                }

                case CD_OPT_SDK_IOS: {
                    sdkIOSOption = [NSString stringWithUTF8String:optarg];
                    break;
                }

                case CD_OPT_SDK_ROOT: {
                    sdkRootOption = [NSString stringWithUTF8String:optarg];
                    break;
                }

                case CD_OPT_HIDE: {
                    NSString *str = [NSString stringWithUTF8String:optarg];
                    if ([str isEqualToString:@"all"]) {
                        [hiddenSections addObject:@"structures"];
                        [hiddenSections addObject:@"protocols"];
                    } else {
                        [hiddenSections addObject:str];
                    }
                    break;
                }

                case 'F':
                    [classFilter addObject:[NSString stringWithUTF8String:optarg]];
                    break;

                case 'X':
                    xibBaseDirectory = [NSString stringWithUTF8String:optarg];
                    break;

                case 'O':
                    symbolsPath = [NSString stringWithUTF8String:optarg];
                    break;

                case 'm':
                    symbolMappingPath = [NSString stringWithUTF8String:optarg];
                    break;

                case 'x':
                    [ignoreSymbols addObject:[NSString stringWithUTF8String:optarg]];
                    break;

                case 't':
                    classDump.shouldShowHeader = NO;
                    break;

                case PPIOS_OPT_EMIT_SDK_SYMBOLS:
                    classDump.excludedSymbolsListFilename = [NSString stringWithUTF8String:optarg];
                    break;

                //modes..
                case PPIOS_OPT_ANALYZE:
                    //do analysis
                    shouldAnalyze = YES;
                    checkSingleMode(hasMode);
                    break;

                case PPIOS_OPT_OBFUSCATE:
                    shouldObfuscate = YES;
                    checkSingleMode(hasMode);
                    break;

                case CD_OPT_LIST_ARCHES:
                    shouldListArches = YES;
                    checkSingleMode(hasMode);
                    break;

                case CD_OPT_VERSION:
                    shouldPrintVersion = YES;
                    checkSingleMode(hasMode);
                    break;

                case CD_OPT_TRANSLATE_DSYM:
                    shouldTranslateDsym = YES;
                    checkSingleMode(hasMode);
                    break;
                case CD_OPT_TRANSLATE_CRASH:
                    shouldTranslateCrashDump = YES;
                    checkSingleMode(hasMode);
                    break;

                case 'h':
                    shouldShowUsage = YES;
                    break;

                default:
                    errorFlag = YES;
                    break;
            }

            hasMode = shouldAnalyze | shouldListArches | shouldObfuscate | shouldPrintVersion |
                    shouldTranslateCrashDump | shouldTranslateDsym;
        }
        if (errorFlag) {
            print_usage();
            exit(2);
        }
        if(shouldShowUsage){
            print_usage();
            exit(0);
        }

        if (!symbolMappingPath) {
            symbolMappingPath = defaultSymbolMappingPath;
        }

        NSString *firstArg = nil;
        if (optind < argc) {
            firstArg = [NSString stringWithFileSystemRepresentation:argv[optind]];
        }
        NSString *secondArg = nil;
        if(optind + 1 < argc ){
            secondArg = [NSString stringWithFileSystemRepresentation:argv[optind + 1]];
        }


        if(!hasMode){
            print_usage();
            exit(2);
        }


        if (shouldPrintVersion) {
            printf("PreEmptive Protection for iOS - Class Guard, version %s\n", CLASS_DUMP_VERSION);
        } else if (shouldListArches) {
            if(firstArg == nil){
                reportError(1, "Input file must be specified for --list-arches");
            }
            NSString *executablePath = nil;
            executablePath = [firstArg executablePathForFilename];
            if (executablePath == nil) {
                reportError(1, "Input file (%s) doesn't contain an executable.", [firstArg fileSystemRepresentation]);
            }
            CDSearchPathState *searchPathState = [[CDSearchPathState alloc] init];
            searchPathState.executablePath = executablePath;
            id macho = [CDFile fileWithContentsOfFile:executablePath searchPathState:searchPathState];
            if (macho != nil) {
                if ([macho isKindOfClass:[CDMachOFile class]]) {
                    printf("%s\n", [[macho archName] UTF8String]);
                } else if ([macho isKindOfClass:[CDFatFile class]]) {
                    printf("%s\n", [[[macho archNames] componentsJoinedByString:@" "] UTF8String]);
                }
            }
        }else if(shouldAnalyze){
            if(firstArg == nil){
                reportError(1, "Input file must be specified for --analyze");
            }
            NSString *executablePath = nil;
            executablePath = [firstArg executablePathForFilename];
            if (executablePath == nil) {
                reportError(1, "Input file (%s) doesn't contain an executable.", [firstArg fileSystemRepresentation]);
            }
            classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];

            classDump.sdkRoot = resolveSDKPath(fileManager, sdkRootOption, sdkIOSOption);

            CDFile *file = [CDFile fileWithContentsOfFile:executablePath searchPathState:classDump.searchPathState];
            if (file == nil) {
                if ([fileManager fileExistsAtPath:executablePath]) {
                    if ([fileManager isReadableFileAtPath:executablePath]) {
                        reportError(1, "Input file (%s) is neither a Mach-O file nor a fat archive.", [executablePath UTF8String]);
                    } else {
                        reportError(1, "Input file (%s) is not readable (check read permissions).", [executablePath UTF8String]);
                    }
                } else {
                    reportError(1, "Input file (%s) does not exist.", [executablePath UTF8String]);
                }
            }

            if (hasSpecifiedArch == NO) {
                if ([file bestMatchForLocalArch:&targetArch] == NO) {
                    reportError(1, "Error: Couldn't get local architecture");
                }
            }

            classDump.targetArch = targetArch;
            classDump.searchPathState.executablePath = [executablePath stringByDeletingLastPathComponent];

            NSError *error;
            if (![classDump loadFile:file error:&error depth:0]) {
                reportError(1, "Error: %s", [[error localizedFailureReason] UTF8String]);
            }

            [classDump processObjectiveCData];
            [classDump registerTypes];

            CDCoreDataModelProcessor *coreDataModelProcessor = [[CDCoreDataModelProcessor alloc] init];
            [classFilter addObjectsFromArray:[coreDataModelProcessor coreDataModelSymbolsToExclude]];


            CDSystemProtocolsProcessor *systemProtocolsProcessor = [[CDSystemProtocolsProcessor alloc] initWithSdkPath:classDump.sdkRoot];
            [ignoreSymbols addObjectsFromArray:[systemProtocolsProcessor systemProtocolsSymbolsToExclude]];

            CDSymbolsGeneratorVisitor *visitor = [CDSymbolsGeneratorVisitor new];
            visitor.classDump = classDump;
            visitor.classFilter = classFilter;
            visitor.ignoreSymbols = ignoreSymbols;
            visitor.symbolsFilePath = symbolsPath;
            visitor.excludedSymbolsListFilename = classDump.excludedSymbolsListFilename;

            [classDump recursivelyVisit:visitor];
            CDSymbolMapper *mapper = [[CDSymbolMapper alloc] init];
            [mapper writeSymbolsFromSymbolsVisitor:visitor toFile:symbolMappingPath];
        } else if(shouldObfuscate){
            int result = [classDump obfuscateSourcesUsingMap:symbolMappingPath
                                           symbolsHeaderFile:symbolsPath
                                            workingDirectory:@"."
                                                xibDirectory:xibBaseDirectory];
            if (result != 0) {
                // errors already reported
                exit(result);
            }
        } else if(shouldTranslateCrashDump) {
            if (!firstArg) {
                reportError(4, "Crash dump file must be specified");
            }
            NSString* crashDumpPath = firstArg;
            NSString *crashDump = [NSString stringWithContentsOfFile:crashDumpPath encoding:NSUTF8StringEncoding error:nil];
            if (crashDump.length == 0) {
                reportError(4, "Crash dump file does not exist or is empty %s", [crashDumpPath fileSystemRepresentation]);
            }

            NSString *symbolsData = [NSString stringWithContentsOfFile:symbolMappingPath encoding:NSUTF8StringEncoding error:nil];
            if (symbolsData.length == 0) {
                reportError(5, "Symbols file does not exist or is empty %s", [symbolMappingPath fileSystemRepresentation]);
            }

            CDSymbolMapper *mapper = [[CDSymbolMapper alloc] init];
            NSString *processedFile = [mapper processCrashDump:crashDump withSymbols:[NSJSONSerialization JSONObjectWithData:[symbolsData dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]];
            [processedFile writeToFile:crashDumpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else if (shouldTranslateDsym){
            NSString *dSYMInPath = firstArg;
            NSString *dSYMOutPath = secondArg;

            if(!dSYMInPath) {
                reportError(5, "No valid dSYM input path provided");
            }
            if(!dSYMOutPath) {
                reportError(5, "No valid dSYM output path provided");
            }
            NSString *symbolsData = [NSString stringWithContentsOfFile:symbolMappingPath encoding:NSUTF8StringEncoding error:nil];
            if (symbolsData.length == 0) {
                reportError(5, "Symbols file does not exist or is empty %s", [symbolMappingPath fileSystemRepresentation]);
            }

            BOOL isDirectory = NO;
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:dSYMInPath isDirectory:&isDirectory];
            if(exists){
                if(!isDirectory){
                    reportError(5, "Input dSYM path provided is invalid %s", [dSYMInPath fileSystemRepresentation]);
                }
            }else{
                reportError(5, "Input dSYM path provided does not exist %s", [dSYMInPath fileSystemRepresentation]);
            }

            CDdSYMProcessor *processor = [[CDdSYMProcessor alloc] init];
            NSArray *dwarfFilesPaths = [processor extractDwarfPathsForDSYM:dSYMInPath];

            for (NSString *dwarfFilePath in dwarfFilesPaths) {
                NSData *dwarfdumpData = [NSData dataWithContentsOfFile:dwarfFilePath];
                if (dwarfdumpData.length == 0) {
                    reportError(4, "DWARF file does not exist or is empty %s", [dwarfFilePath fileSystemRepresentation]);
                }

                NSData *processedFileContent = [processor processDwarfdump:dwarfdumpData
                                                               withSymbols:[NSJSONSerialization JSONObjectWithData:[symbolsData dataUsingEncoding:NSUTF8StringEncoding]
                                                                                                           options:0
                                                                                                             error:nil]];
                [processor writeDwarfdump:processedFileContent originalDwarfPath:dwarfFilePath inputDSYM:dSYMInPath outputDSYM:dSYMOutPath];
            }
        }
        exit(0); // avoid costly autorelease pool drain, we’re exiting anyway
    }
}

static NSString * resolveSDKPath(NSFileManager * fileManager,
                                 NSString * const sdkRootOption,
                                 NSString * const sdkIOSOption) {

    NSString * const SDK_PATH_PATTERN
            = [NSString stringWithUTF8String:SDK_PATH_BEFORE "%@" SDK_PATH_AFTER];

    if ((sdkRootOption != nil) && (sdkIOSOption != nil)) {
        reportError(1, "Specify only one of --sdk-root or --sdk-ios");
    }

    BOOL specified = YES;
    NSString * sdkPath;
    if (sdkRootOption == nil) {
        NSString * version = sdkIOSOption;
        if (version == nil) {
            specified = NO;
            version = @"";
        }

        sdkPath = [NSString stringWithFormat:SDK_PATH_PATTERN, version];
    } else {
        sdkPath = sdkRootOption;
    }

    if (![fileManager fileExistsAtPath:sdkPath]) {
        reportError(1,
                "%s SDK does not exist: %s",
                (specified ? "Specified" : "Default"),
                [sdkPath UTF8String]);
    }

    return sdkPath;
}
