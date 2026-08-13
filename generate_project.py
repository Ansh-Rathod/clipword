#!/usr/bin/env python3
import os
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "Clipword")

def uid():
    return uuid.uuid4().hex[:24].upper()

PROJECT_ID = uid()
TARGET_ID = uid()
SOURCES_PHASE = uid()
RESOURCES_PHASE = uid()
FRAMEWORKS_PHASE = uid()
PRODUCT_REF = uid()
CONFIG_LIST_PROJ = uid()
CONFIG_LIST_TARGET = uid()
DEBUG_CONFIG = uid()
RELEASE_CONFIG = uid()
DEBUG_CONFIG_TARGET = uid()
RELEASE_CONFIG_TARGET = uid()

# SPM package references
packages = {
    "Defaults": ("https://github.com/sindresorhus/Defaults", "8.0.0"),
    "KeyboardShortcuts": ("https://github.com/sindresorhus/KeyboardShortcuts", "2.0.0"),
    "Fuse": ("https://github.com/krisk/fuse-swift", "1.0.0"),
}

pkg_ids = {name: uid() for name in packages}
pkg_prod_ids = {name: uid() for name in packages}
pkg_ref_group = uid()
products_group = uid()
main_group = uid()
clipword_group = uid()

swift_files = []
for dirpath, _, filenames in os.walk(SRC):
    for f in filenames:
        if f.endswith(".swift"):
            full = os.path.join(dirpath, f)
            rel_to_clipword = os.path.relpath(full, SRC)
            swift_files.append(rel_to_clipword)

swift_files.sort()
file_refs = {}
build_files = {}
for sf in swift_files:
    fid = uid()
    bid = uid()
    file_refs[sf] = (fid, bid)

resource_files = [
    "Resources/Assets.xcassets",
    "Resources/Info.plist",
    "Clipword.entitlements",
]

res_refs = {}
res_build = {}
for rf in resource_files:
    fid = uid()
    bid = uid()
    res_refs[rf] = (fid, bid)

lines = []
def w(s=""):
    lines.append(s)

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 60;")
w("\tobjects = {")

# PBXBuildFile for swift
for sf, (fid, bid) in file_refs.items():
    w(f"\t\t{bid} /* {os.path.basename(sf)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {os.path.basename(sf)} */; }};")

for rf, (fid, bid) in res_refs.items():
    name = os.path.basename(rf)
    if name.endswith(".xcassets"):
        w(f"\t\t{bid} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {fid} /* {name} */; }};")

# SPM product dependencies
for name in packages:
    w(f"\t\t{uid()} /* {name} in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_prod_ids[name]} /* {name} */; }};")

# File references
for sf, (fid, _) in file_refs.items():
    w(f"\t\t{fid} /* {os.path.basename(sf)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {sf}; sourceTree = \"<group>\"; }};")

w(f"\t\t{PRODUCT_REF} /* Clipword.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Clipword.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

for rf, (fid, _) in res_refs.items():
    name = os.path.basename(rf)
    if name.endswith(".xcassets"):
        w(f"\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {rf}; sourceTree = \"<group>\"; }};")
    elif name.endswith(".plist"):
        w(f"\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {rf}; sourceTree = \"<group>\"; }};")
    else:
        w(f"\t\t{fid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {rf}; sourceTree = \"<group>\"; }};")

# Frameworks phase build files for SPM
fw_build_ids = []
for name in packages:
    bid = uid()
    fw_build_ids.append(bid)
    w(f"\t\t{bid} /* {name} in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkg_prod_ids[name]} /* {name} */; }};")

# Groups
w(f"\t\t{products_group} /* Products */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{PRODUCT_REF} /* Clipword.app */,")
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w(f"\t\t{clipword_group} /* Clipword */ = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for sf, (fid, _) in file_refs.items():
    w(f"\t\t\t\t{fid} /* {os.path.basename(sf)} */,")
for rf, (fid, _) in res_refs.items():
    w(f"\t\t\t\t{fid} /* {os.path.basename(rf)} */,")
w("\t\t\t);")
w("\t\t\tpath = Clipword;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w(f"\t\t{main_group} = {{")
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w(f"\t\t\t\t{clipword_group} /* Clipword */,")
w(f"\t\t\t\t{products_group} /* Products */,")
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

# PBXFrameworksBuildPhase
w(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
w("\t\t\tisa = PBXFrameworksBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for bid in fw_build_ids:
    w(f"\t\t\t\t{bid} /* Frameworks */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")

# PBXNativeTarget
w(f"\t\t{TARGET_ID} /* Clipword */ = {{")
w("\t\t\tisa = PBXNativeTarget;")
w(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget \"Clipword\" */;")
w("\t\t\tbuildPhases = (")
w(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
w(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
w(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w("\t\t\tname = Clipword;")
w(f"\t\t\tpackageProductDependencies = (")
for name in packages:
    w(f"\t\t\t\t{pkg_prod_ids[name]} /* {name} */,")
w("\t\t\t);")
w(f"\t\t\tproductName = Clipword;")
w(f"\t\t\tproductReference = {PRODUCT_REF} /* Clipword.app */;")
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")

# PBXProject
w(f"\t\t{PROJECT_ID} /* Project object */ = {{")
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 1600;")
w("\t\t\t\tLastUpgradeCheck = 1600;")
w("\t\t\t};")
w(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_PROJ} /* Build configuration list for PBXProject \"Clipword\" */;")
w("\t\t\tcompatibilityVersion = \"Xcode 15.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t);")
w(f"\t\t\tmainGroup = {main_group};")
w("\t\t\tpackageReferences = (")
for name, (url, ver) in packages.items():
    w(f"\t\t\t\t{pkg_ids[name]} /* XCRemoteSwiftPackageReference \"{name}\" */,")
w("\t\t\t);")
w(f"\t\t\tproductRefGroup = {products_group} /* Products */;")
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w(f"\t\t\t\t{TARGET_ID} /* Clipword */,")
w("\t\t\t);")
w("\t\t};")

# Resources
w(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
w("\t\t\tisa = PBXResourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for rf, (_, bid) in res_refs.items():
    if os.path.basename(rf).endswith(".xcassets"):
        w(f"\t\t\t\t{bid} /* {os.path.basename(rf)} in Resources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")

# Sources
w(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for sf, (_, bid) in file_refs.items():
    w(f"\t\t\t\t{bid} /* {os.path.basename(sf)} in Sources */,")
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")

# XCRemoteSwiftPackageReference
for name, (url, ver) in packages.items():
    w(f"\t\t{pkg_ids[name]} /* XCRemoteSwiftPackageReference \"{name}\" */ = {{")
    w("\t\t\tisa = XCRemoteSwiftPackageReference;")
    w(f"\t\t\trepositoryURL = \"{url}\";")
    w("\t\t\trequirement = {")
    w("\t\t\t\tkind = upToNextMajorVersion;")
    w(f"\t\t\t\tminimumVersion = {ver};")
    w("\t\t\t};")
    w("\t\t};")

# XCSwiftPackageProductDependency
product_map = {
    "Defaults": "Defaults",
    "KeyboardShortcuts": "KeyboardShortcuts",
    "Fuse": "Fuse",
}
for name, prod in product_map.items():
    w(f"\t\t{pkg_prod_ids[name]} /* {prod} */ = {{")
    w("\t\t\tisa = XCSwiftPackageProductDependency;")
    w(f"\t\t\tpackage = {pkg_ids[name]} /* XCRemoteSwiftPackageReference \"{name}\" */;")
    w(f"\t\t\tproductName = {prod};")
    w("\t\t};")

# Build configurations
for cid, name, is_proj in [
    (DEBUG_CONFIG, "Debug", True),
    (RELEASE_CONFIG, "Release", True),
    (DEBUG_CONFIG_TARGET, "Debug", False),
    (RELEASE_CONFIG_TARGET, "Release", False),
]:
    w(f"\t\t{cid} /* {name} */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    if is_proj:
        w("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        w("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        w("\t\t\t\tCOPY_PHASE_STRIP = NO;")
        w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
        w("\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;")
        w("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
        w("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 15.0;")
        w("\t\t\t\tONLY_ACTIVE_ARCH = YES;" if name == "Debug" else "\t\t\t\tONLY_ACTIVE_ARCH = NO;")
        w("\t\t\t\tSDKROOT = macosx;")
        w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";" if name == "Debug" else "")
        w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";" if name == "Debug" else "\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
    else:
        w("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        w("\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;")
        w("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Clipword/Clipword.entitlements;")
        w("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        w("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
        w("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        w("\t\t\t\tDEVELOPMENT_TEAM = \"\";")
        w("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
        w("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        w("\t\t\t\tINFOPLIST_FILE = Clipword/Resources/Info.plist;")
        w("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
        w("\t\t\t\t\t\"$(inherited)\",")
        w("\t\t\t\t\t\"@executable_path/../Frameworks\",")
        w("\t\t\t\t);")
        w("\t\t\t\tMARKETING_VERSION = 1.0;")
        w("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.clipword.app;")
        w("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        w("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
        w("\t\t\t\tSWIFT_EMIT_APP_INTENTS_METADATA = NO;")
        w("\t\t\t\tSWIFT_VERSION = 6.0;")
    w("\t\t\t};")
    w(f"\t\t\tname = {name};")
    w("\t\t};")

w(f"\t\t{CONFIG_LIST_PROJ} /* Build configuration list for PBXProject \"Clipword\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{DEBUG_CONFIG} /* Debug */,")
w(f"\t\t\t\t{RELEASE_CONFIG} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")

w(f"\t\t{CONFIG_LIST_TARGET} /* Build configuration list for PBXNativeTarget \"Clipword\" */ = {{")
w("\t\t\tisa = XCConfigurationList;")
w("\t\t\tbuildConfigurations = (")
w(f"\t\t\t\t{DEBUG_CONFIG_TARGET} /* Debug */,")
w(f"\t\t\t\t{RELEASE_CONFIG_TARGET} /* Release */,")
w("\t\t\t);")
w("\t\t\tdefaultConfigurationIsVisible = 0;")
w("\t\t\tdefaultConfigurationName = Release;")
w("\t\t};")

w("\t};")
w(f"\trootObject = {PROJECT_ID} /* Project object */;")
w("}")

out_dir = os.path.join(ROOT, "Clipword.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "project.pbxproj"), "w") as f:
    f.write("\n".join(lines))

scheme = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "%s"
               BuildableName = "Clipword.app"
               BlueprintName = "Clipword"
               ReferencedContainer = "container:Clipword.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "%s"
            BuildableName = "Clipword.app"
            BlueprintName = "Clipword"
            ReferencedContainer = "container:Clipword.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
""" % (TARGET_ID, TARGET_ID)

scheme_dir = os.path.join(out_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
with open(os.path.join(scheme_dir, "Clipword.xcscheme"), "w") as f:
    f.write(scheme)

print("Generated Clipword.xcodeproj")
