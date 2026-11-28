"""Generate native Xcode app + Camera Extension targets without XcodeGen."""
from pathlib import Path
import hashlib
import plistlib
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parents[1]
objects={}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_key,isa,**fields):
    key=ident(object_key);objects[key]=dict(isa=isa,**fields);return key
def file(path,kind): return add('file:'+path,'PBXFileReference',path=path,sourceTree='<group>',lastKnownFileType=kind)
project=ident('project');app=ident('app');extension=ident('extension');controls=ident('controls');publisher=ident('publisher');browser_host=ident('browser-host');safari=ident('safari')
config=file('Config/Project.xcconfig','text.xcconfig')
app_product=add('app-product','PBXFileReference',path='Locked Gaze.app',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.application')
ext_product=add('extension-product','PBXFileReference',path='local.lockedgaze.app.camera.systemextension',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.system-extension')
controls_product=add('controls-product','PBXFileReference',path='LockedGazeControls.appex',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.app-extension')
publisher_product=add('publisher-product','PBXFileReference',path='LockedGazePublisher.xpc',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.xpc-service')
browser_host_product=add('browser-host-product','PBXFileReference',path='LockedGazeBrowserHost',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='compiled.mach-o.executable')
safari_product=add('safari-product','PBXFileReference',path='LockedGazeSafari.appex',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.app-extension')
products=add('products','PBXGroup',name='Products',sourceTree='<group>',children=[app_product,ext_product,controls_product,publisher_product,browser_host_product,safari_product])
children=[config]
source_refs={}
for path in sorted([*root.glob('Sources/**/*.swift'),*root.glob('Native/*.mm')]):
    relative=str(path.relative_to(root));ref=file(relative,'sourcecode.swift' if path.suffix=='.swift' else 'sourcecode.cpp.objcpp');children.append(ref);source_refs[relative]=ref
models=file('build/Models','folder');children.append(models)
# Icon Composer document: actool compiles it into Assets.car (Liquid Glass on macOS 26+) and AppIcon.icns.
icon=file('Resources/AppIcon.icon','folder.iconcomposer.icon');children.append(icon)
for p in ['Native/include/LGFramePipeline.h','Config/App.entitlements','Config/Camera.entitlements','Config/App-Info.plist','Config/Camera-Info.plist','Config/Publisher-Info.plist','Config/Publisher.entitlements','Config/BrowserHost-Info.plist','Config/BrowserHost.entitlements','Config/Safari-Info.plist','Config/Safari.entitlements']:
    children.append(file(p,'sourcecode.c.h' if p.endswith('.h') else 'text.plist.xml'))
group=add('root-group','PBXGroup',sourceTree='<group>',children=children+[products])
def configs(name,settings):
    configurations=[]
    for configuration in ['Debug','Release']:
        build=dict(settings)
        build.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if configuration=='Debug' else '-O',GCC_OPTIMIZATION_LEVEL='0' if configuration=='Debug' else '3',DEBUG_INFORMATION_FORMAT='dwarf' if configuration=='Debug' else 'dwarf-with-dsym')
        configurations.append(add(name+configuration,'XCBuildConfiguration',name=configuration,baseConfigurationReference=config,buildSettings=build))
    return add(name+'configs','XCConfigurationList',buildConfigurations=configurations,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
project_configs=configs('project-',{})
common=dict(PRODUCT_NAME='$(TARGET_NAME)',SWIFT_EMIT_LOC_STRINGS='NO',COMBINE_HIDPI_IMAGES='YES')
app_settings=dict(common,PRODUCT_NAME='Locked Gaze',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app',INFOPLIST_FILE='Config/App-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/App.entitlements',
    SWIFT_OBJC_BRIDGING_HEADER='Native/include/LGFramePipeline.h',HEADER_SEARCH_PATHS=['$(inherited)','$(SRCROOT)/Native/include','$(SRCROOT)/build/deps/opencv/include/opencv4'],
    LIBRARY_SEARCH_PATHS=['$(inherited)','$(SRCROOT)/build/deps/opencv/lib','$(SRCROOT)/build/deps/opencv/lib/opencv4/3rdparty'],
    OTHER_LDFLAGS=['$(inherited)','-lopencv_calib3d','-lopencv_features2d','-lopencv_flann','-lopencv_imgproc','-lopencv_core','-ltegra_hal','-lc++','-lz','-framework','Accelerate'],
    LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks'])
ext_settings=dict(common,PRODUCT_NAME='local.lockedgaze.app.camera',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app.camera',INFOPLIST_FILE='Config/Camera-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/Camera.entitlements',SKIP_INSTALL='YES',ENABLE_APP_SANDBOX='YES',INSTALL_PATH='$(LOCAL_LIBRARY_DIR)/SystemExtensions')
prepare=add('prepare','PBXShellScriptBuildPhase',buildActionMask='2147483647',files=[],name='Prepare native dependencies and Core ML models',shellPath='/bin/bash',shellScript='bash "$SRCROOT/scripts/prepare-resources.sh"\n',runOnlyForDeploymentPostprocessing='0',alwaysOutOfDate='1')
def sources(name,predicate):
    files=[add(name+path,'PBXBuildFile',fileRef=ref) for path,ref in source_refs.items() if predicate(path)]
    return add(name+'sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=files,runOnlyForDeploymentPostprocessing='0')
app_sources=sources('app-',lambda p:p.startswith(('Sources/App/','Sources/Core/','Sources/Shared/','Sources/ControlSupport/','Sources/PublisherIPC/','Sources/BrowserIPC/','Native/')))
ext_sources=sources('extension-',lambda p:p.startswith(('Sources/CameraExtension/','Sources/Shared/')))
resource_file=add('models-resource','PBXBuildFile',fileRef=models)
resources=add('resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[resource_file,add('icon-resource','PBXBuildFile',fileRef=icon)],runOnlyForDeploymentPostprocessing='0')
proxy=add('extension-proxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=extension,remoteInfo='LockedGazeCamera')
dependency=add('extension-dependency','PBXTargetDependency',target=extension,targetProxy=proxy)
embed_file=add('embed-extension-file','PBXBuildFile',fileRef=ext_product,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
embed=add('embed-extension','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions',dstSubfolderSpec='16',files=[embed_file],name='Embed Camera Extension',runOnlyForDeploymentPostprocessing='0')
controls_settings=dict(common,PRODUCT_NAME='LockedGazeControls',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app.controls',INFOPLIST_FILE='Config/Controls-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/Controls.entitlements',SKIP_INSTALL='YES',ENABLE_APP_SANDBOX='YES',APPLICATION_EXTENSION_API_ONLY='YES',MACOSX_DEPLOYMENT_TARGET='14.0')
controls_sources=sources('controls-',lambda p:p.startswith(('Sources/Controls/','Sources/ControlSupport/')) or p=='Sources/Core/GazeMode.swift')
controls_icon=add('controls-icon','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[add('controls-icon-resource','PBXBuildFile',fileRef=icon)],runOnlyForDeploymentPostprocessing='0')
controls_proxy=add('controls-proxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=controls,remoteInfo='LockedGazeControls')
controls_dependency=add('controls-dependency','PBXTargetDependency',target=controls,targetProxy=controls_proxy)
controls_embed_file=add('embed-controls-file','PBXBuildFile',fileRef=controls_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
controls_embed=add('embed-controls','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[controls_embed_file],name='Embed Controls',runOnlyForDeploymentPostprocessing='0')
add('controls','PBXNativeTarget',name='LockedGazeControls',productName='LockedGazeControls',productType='com.apple.product-type.app-extension',productReference=controls_product,buildConfigurationList=configs('controls-',controls_settings),buildPhases=[controls_sources,controls_icon],buildRules=[],dependencies=[])
publisher_settings=dict(common,PRODUCT_NAME='LockedGazePublisher',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app.publisher',INFOPLIST_FILE='Config/Publisher-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/Publisher.entitlements',SKIP_INSTALL='YES')
publisher_sources=sources('publisher-',lambda p:p.startswith(('Sources/PublisherService/','Sources/PublisherIPC/')) or p in ['Sources/Shared/CameraContract.swift','Sources/Core/GazeError.swift','Sources/Core/StartupRetry.swift'])
publisher_proxy=add('publisher-proxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=publisher,remoteInfo='LockedGazePublisher')
publisher_dependency=add('publisher-dependency','PBXTargetDependency',target=publisher,targetProxy=publisher_proxy)
publisher_embed_file=add('embed-publisher-file','PBXBuildFile',fileRef=publisher_product,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
publisher_embed=add('embed-publisher','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='16',files=[publisher_embed_file],name='Embed Publisher Service',runOnlyForDeploymentPostprocessing='0')
# XPC services live inside the application's Contents/XPCServices directory.
objects[publisher_embed]['dstPath']='$(CONTENTS_FOLDER_PATH)/XPCServices'
add('publisher','PBXNativeTarget',name='LockedGazePublisher',productName='LockedGazePublisher',productType='com.apple.product-type.xpc-service',productReference=publisher_product,buildConfigurationList=configs('publisher-',publisher_settings),buildPhases=[publisher_sources],buildRules=[],dependencies=[])
# Chrome starts this helper over Native Messaging (LG-009). It lives in Contents/Helpers,
# sandboxed in the App Group, and carries its Info.plist inside the executable.
browser_host_settings=dict(common,PRODUCT_NAME='LockedGazeBrowserHost',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app.browser-host',INFOPLIST_FILE='Config/BrowserHost-Info.plist',CREATE_INFOPLIST_SECTION_IN_BINARY='YES',CODE_SIGN_ENTITLEMENTS='Config/BrowserHost.entitlements',SKIP_INSTALL='YES',ENABLE_APP_SANDBOX='YES')
browser_host_sources=sources('browser-host-',lambda p:p.startswith(('Sources/BrowserHost/','Sources/BrowserIPC/')))
browser_host_proxy=add('browser-host-proxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=browser_host,remoteInfo='LockedGazeBrowserHost')
browser_host_dependency=add('browser-host-dependency','PBXTargetDependency',target=browser_host,targetProxy=browser_host_proxy)
browser_host_embed_file=add('embed-browser-host-file','PBXBuildFile',fileRef=browser_host_product,settings={'ATTRIBUTES':['CodeSignOnCopy']})
browser_host_embed=add('embed-browser-host','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='Contents/Helpers',dstSubfolderSpec='1',files=[browser_host_embed_file],name='Embed Browser Helper',runOnlyForDeploymentPostprocessing='0')
add('browser-host','PBXNativeTarget',name='LockedGazeBrowserHost',productName='LockedGazeBrowserHost',productType='com.apple.product-type.tool',productReference=browser_host_product,buildConfigurationList=configs('browser-host-',browser_host_settings),buildPhases=[browser_host_sources],buildRules=[],dependencies=[])
# Safari Web Extension (LG-009): the web scripts are shared with the Chrome extension.
safari_web_files=['Extensions/Safari/manifest.json','Extensions/Safari/background.js','Extensions/Shared/inject-main.js','Extensions/Shared/inject-bridge.js','Extensions/Shared/site-access.js']
safari_web_refs=[file(p,'text.json' if p.endswith('.json') else 'sourcecode.javascript') for p in safari_web_files]
# Copied as a folder, so manifests can refer to icons/icon-N.png.
extension_icons=file('Extensions/Shared/icons','folder')
safari_web_files.append('Extensions/Shared/icons'); safari_web_refs.append(extension_icons)
objects[group]['children'][-1:-1]=safari_web_refs
safari_settings=dict(common,PRODUCT_NAME='LockedGazeSafari',PRODUCT_BUNDLE_IDENTIFIER='local.lockedgaze.app.safari',INFOPLIST_FILE='Config/Safari-Info.plist',CODE_SIGN_ENTITLEMENTS='Config/Safari.entitlements',SKIP_INSTALL='YES',ENABLE_APP_SANDBOX='YES',APPLICATION_EXTENSION_API_ONLY='YES')
safari_sources=sources('safari-',lambda p:p.startswith(('Sources/SafariExtension/','Sources/BrowserIPC/')))
safari_resources=add('safari-resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=[add('safari-resource-'+p,'PBXBuildFile',fileRef=r) for p,r in zip(safari_web_files,safari_web_refs)],runOnlyForDeploymentPostprocessing='0')
safari_proxy=add('safari-proxy','PBXContainerItemProxy',containerPortal=project,proxyType='1',remoteGlobalIDString=safari,remoteInfo='LockedGazeSafari')
safari_dependency=add('safari-dependency','PBXTargetDependency',target=safari,targetProxy=safari_proxy)
safari_embed_file=add('embed-safari-file','PBXBuildFile',fileRef=safari_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
add('safari','PBXNativeTarget',name='LockedGazeSafari',productName='LockedGazeSafari',productType='com.apple.product-type.app-extension',productReference=safari_product,buildConfigurationList=configs('safari-',safari_settings),buildPhases=[safari_sources,safari_resources],buildRules=[],dependencies=[])
objects[controls_embed]['files'].append(safari_embed_file)
# The Chrome extension ships inside the app until it is on the Chrome Web Store: Set Up
# Google Chrome saves it to a folder the user loads with Load unpacked.
chrome_web_files=['Extensions/Chrome/manifest.json','Extensions/Chrome/background.js']
chrome_web_refs=[file(p,'text.json' if p.endswith('.json') else 'sourcecode.javascript') for p in chrome_web_files]
objects[group]['children'][-1:-1]=chrome_web_refs
chrome_copy=add('chrome-extension-copy','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='ChromeExtension',dstSubfolderSpec='7',
    files=[add('chrome-copy-'+p,'PBXBuildFile',fileRef=r) for p,r in zip(chrome_web_files+safari_web_files[2:],chrome_web_refs+safari_web_refs[2:])],
    name='Copy Chrome Extension',runOnlyForDeploymentPostprocessing='0')
add('app','PBXNativeTarget',name='LockedGaze',productName='Locked Gaze',productType='com.apple.product-type.application',productReference=app_product,buildConfigurationList=configs('app-',app_settings),buildPhases=[prepare,app_sources,resources,chrome_copy,embed,controls_embed,publisher_embed,browser_host_embed],buildRules=[],dependencies=[dependency,controls_dependency,publisher_dependency,browser_host_dependency,safari_dependency])
add('extension','PBXNativeTarget',name='LockedGazeCamera',productName='local.lockedgaze.app.camera',productType='com.apple.product-type.system-extension',productReference=ext_product,buildConfigurationList=configs('extension-',ext_settings),buildPhases=[ext_sources],buildRules=[],dependencies=[])
add('project','PBXProject',attributes={'LastUpgradeCheck':'2700','BuildIndependentTargetsInParallel':'YES'},buildConfigurationList=project_configs,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,extension,controls,publisher,browser_host,safari])
directory=root/'LockedGaze.xcodeproj';directory.mkdir(exist_ok=True)
(directory/'project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project),sort_keys=False))
# The camera extension keeps its own version, 1.0.1 (15) as shipped. macOS replaces an installed
# camera extension whenever this changes, and Core Media I/O can then leave no camera running
# until a restart. Change it only when installed Macs must
# receive a new extension.
versions={'APPL':('1.2.0','35'),'SYSX':('1.0.1','15')}
for filename,identifier,kind in [('App-Info.plist','local.lockedgaze.app','APPL'),('Camera-Info.plist','local.lockedgaze.app.camera','SYSX')]:
    info=dict(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleName='Locked Gaze',CFBundleDisplayName='Locked Gaze',CFBundlePackageType=kind,CFBundleVersion=versions[kind][1],CFBundleShortVersionString=versions[kind][0],LSMinimumSystemVersion='$(MACOSX_DEPLOYMENT_TARGET)',NSSystemExtensionUsageDescription='Locked Gaze supplies processed video to other camera apps.')
    if kind=="APPL":info.update(LSApplicationCategoryType="public.app-category.photography",ITSAppUsesNonExemptEncryption=False,CFBundleIconFile="AppIcon",CFBundleDevelopmentRegion="en",LGAppGroup="$(TeamIdentifierPrefix)local.lockedgaze.app",LSUIElement=True,NSCameraUsageDescription='Locked Gaze corrects your gaze locally on this Mac.',NSCameraUseContinuityCameraDeviceType=True,NSHighResolutionCapable=True)
    else:info.update(CMIOExtension={'CMIOExtensionMachServiceName':'$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)'})
    (root/'Config'/filename).write_bytes(plistlib.dumps(info))
(root/'Config/Safari-Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleExecutable='$(EXECUTABLE_NAME)',
    CFBundleName='Locked Gaze Camera',CFBundleDisplayName='Locked Gaze Camera',CFBundlePackageType='XPC!',CFBundleShortVersionString=versions['APPL'][0],CFBundleVersion=versions['APPL'][1],
    CFBundleInfoDictionaryVersion='6.0',LSMinimumSystemVersion='$(MACOSX_DEPLOYMENT_TARGET)',LGAppGroup='$(TeamIdentifierPrefix)local.lockedgaze.app',
    NSHumanReadableDescription='Adds Locked Gaze Camera to Google Meet in Safari.',
    NSExtension=dict(NSExtensionPointIdentifier='com.apple.Safari.web-extension',NSExtensionPrincipalClass='$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler'))))
(root/'Config/BrowserHost-Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleName='Locked Gaze Browser Helper',
    CFBundleShortVersionString=versions['APPL'][0],CFBundleVersion=versions['APPL'][1],CFBundleInfoDictionaryVersion='6.0',LGAppGroup='$(TeamIdentifierPrefix)local.lockedgaze.app')))
scheme=ET.Element('Scheme',LastUpgradeVersion='2700',version='1.3')
build=ET.SubElement(scheme,'BuildAction',parallelizeBuildables='YES',buildImplicitDependencies='YES')
entries=ET.SubElement(build,'BuildActionEntries');entry=ET.SubElement(entries,'BuildActionEntry',buildForTesting='YES',buildForRunning='YES',buildForProfiling='YES',buildForArchiving='YES',buildForAnalyzing='YES')
def reference(parent):return ET.SubElement(parent,'BuildableReference',BuildableIdentifier='primary',BlueprintIdentifier=app,BuildableName='Locked Gaze.app',BlueprintName='LockedGaze',ReferencedContainer='container:LockedGaze.xcodeproj')
reference(entry)
launch=ET.SubElement(scheme,'LaunchAction',buildConfiguration='Debug',selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB',selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB',launchStyle='0',useCustomWorkingDirectory='NO',ignoresPersistentStateOnLaunch='NO',debugDocumentVersioning='YES',debugServiceExtension='internal',allowLocationSimulation='YES')
reference(ET.SubElement(launch,'BuildableProductRunnable',runnableDebuggingMode='0'))
ET.SubElement(scheme,'AnalyzeAction',buildConfiguration='Debug');ET.SubElement(scheme,'ArchiveAction',buildConfiguration='Release',revealArchiveInOrganizer='YES')
schemes=directory/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
ET.indent(scheme);ET.ElementTree(scheme).write(schemes/'LockedGaze.xcscheme',encoding='UTF-8',xml_declaration=True)
print(directory)
