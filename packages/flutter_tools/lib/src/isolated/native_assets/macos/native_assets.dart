// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:code_assets/code_assets.dart';
import 'package:hooks_runner/hooks_runner.dart';

import '../../../base/file_system.dart';
import '../../../build_info.dart';
import '../native_assets.dart';
import 'native_assets_host.dart';

// TODO(dcharkes): Fetch minimum MacOS version from somewhere. https://github.com/flutter/flutter/issues/145104
const targetMacOSVersion = 13;

/// Extract the [Architecture] from a [DarwinArch].
Architecture getNativeMacOSArchitecture(DarwinArch darwinArch) {
  return switch (darwinArch) {
    DarwinArch.arm64 => Architecture.arm64,
    DarwinArch.x86_64 => Architecture.x64,
    DarwinArch.armv7 => throw Exception('Unknown DarwinArch: $darwinArch.'),
  };
}

Map<KernelAssetPath, List<FlutterCodeAsset>> fatAssetTargetLocationsMacOS(
  List<FlutterCodeAsset> nativeAssets,
  Uri? absolutePath,
) {
  final alreadyTakenNames = <String>{};
  final result = <KernelAssetPath, List<FlutterCodeAsset>>{};
  final idToPath = <String, KernelAssetPath>{};
  for (final asset in nativeAssets) {
    // Use same target path for all assets with the same id.
    final String assetId = asset.codeAsset.id;
    final KernelAssetPath path =
        idToPath[assetId] ?? _targetLocationMacOS(asset, absolutePath, alreadyTakenNames).path;
    idToPath[assetId] = path;
    result[path] ??= <FlutterCodeAsset>[];
    result[path]!.add(asset);
  }
  return result;
}

Map<FlutterCodeAsset, KernelAsset> assetTargetLocationsMacOS(
  List<FlutterCodeAsset> nativeAssets,
  Uri? absolutePath,
) {
  final alreadyTakenNames = <String>{};
  final idToPath = <String, KernelAssetPath>{};
  final result = <FlutterCodeAsset, KernelAsset>{};
  for (final asset in nativeAssets) {
    final String assetId = asset.codeAsset.id;
    final KernelAssetPath path =
        idToPath[assetId] ?? _targetLocationMacOS(asset, absolutePath, alreadyTakenNames).path;
    idToPath[assetId] = path;
    result[asset] = KernelAsset(id: assetId, target: asset.target, path: path);
  }
  return result;
}

KernelAsset _targetLocationMacOS(
  FlutterCodeAsset asset,
  Uri? absolutePath,
  Set<String> alreadyTakenNames,
) {
  final LinkMode linkMode = asset.codeAsset.linkMode;
  final KernelAssetPath kernelAssetPath;
  switch (linkMode) {
    case DynamicLoadingSystem _:
      kernelAssetPath = KernelAssetSystemPath(linkMode.uri);
    case LookupInExecutable _:
      kernelAssetPath = KernelAssetInExecutable();
    case LookupInProcess _:
      kernelAssetPath = KernelAssetInProcess();
    case DynamicLoadingBundled _:
      final String fileName = asset.codeAsset.file!.pathSegments.last;
      Uri uri;
      if (absolutePath != null) {
        // Flutter tester needs full host paths.
        uri = absolutePath.resolve(fileName);
      } else {
        // Flutter Desktop needs "absolute" paths inside the app.
        // "relative" in the context of native assets would be relative to the
        // kernel or aot snapshot.
        uri = frameworkUri(fileName, alreadyTakenNames);
      }
      kernelAssetPath = KernelAssetAbsolutePath(uri);
    default:
      throw Exception('Unsupported asset link mode $linkMode in asset $asset');
  }
  return KernelAsset(id: asset.codeAsset.id, target: asset.target, path: kernelAssetPath);
}

/// Copies native assets into a framework per dynamic library.
///
/// The framework contains symlinks according to
/// https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFrameworks/Concepts/FrameworkAnatomy.html
///
/// For `flutter run -release` a multi-architecture solution is needed. So,
/// `lipo` is used to combine all target architectures into a single file.
///
/// The install name is set so that it matches with the place it will
/// be bundled in the final app. Install names that are referenced in dependent
/// libraries are updated to match the new install name, so that the referenced
/// library can be found the dynamic linker.
///
/// Code signing is also done here, so that it doesn't have to be done in
/// in macos_assemble.sh.
Future<void> copyNativeCodeAssetsMacOS(
  Uri buildUri,
  Map<KernelAssetPath, List<FlutterCodeAsset>> assetTargetLocations,
  String? codesignIdentity,
  BuildMode buildMode,
  FileSystem fileSystem,
) async {
  assert(assetTargetLocations.isNotEmpty);

  final oldToNewInstallNames = <String, String>{};
  final dylibs = <(File, String, Directory)>[];

  for (final MapEntry<KernelAssetPath, List<FlutterCodeAsset>> assetMapping
      in assetTargetLocations.entries) {
    final Uri target = (assetMapping.key as KernelAssetAbsolutePath).uri;
    final sources = <File>[
      for (final FlutterCodeAsset source in assetMapping.value)
        fileSystem.file(source.codeAsset.file),
    ];
    final Uri targetUri = buildUri.resolveUri(target);
    final String name = targetUri.pathSegments.last;
    final Directory frameworkDir = fileSystem.file(targetUri).parent;
    if (await frameworkDir.exists()) {
      await frameworkDir.delete(recursive: true);
    }
    // MyFramework.framework/                           frameworkDir
    //   MyFramework  -> Versions/Current/MyFramework   dylibLink
    //   Resources    -> Versions/Current/Resources     resourcesLink
    //   Versions/                                      versionsDir
    //     A/                                           versionADir
    //       MyFramework                                dylibFile
    //       Resources/                                 resourcesDir
    //         Info.plist
    //     Current  -> A                                currentLink
    final Directory versionsDir = frameworkDir.childDirectory('Versions');
    final Directory versionADir = versionsDir.childDirectory('A');
    final Directory resourcesDir = versionADir.childDirectory('Resources');
    await resourcesDir.create(recursive: true);
    final File dylibFile = versionADir.childFile(name);
    final Link currentLink = versionsDir.childLink('Current');
    await currentLink.create(
      fileSystem.path.relative(versionADir.path, from: currentLink.parent.path),
    );
    final Link resourcesLink = frameworkDir.childLink('Resources');
    await resourcesLink.create(
      fileSystem.path.relative(resourcesDir.path, from: resourcesLink.parent.path),
    );
    await lipoDylibs(dylibFile, sources);
    final Link dylibLink = frameworkDir.childLink(name);
    await dylibLink.create(
      fileSystem.path.relative(
        versionsDir.childDirectory('Current').childFile(name).path,
        from: dylibLink.parent.path,
      ),
    );

    final String dylibFileName = dylibFile.basename;
    final newInstallName = '@rpath/$dylibFileName.framework/$dylibFileName';
    final Set<String> oldInstallNames = await getInstallNamesDylib(dylibFile);
    for (final oldInstallName in oldInstallNames) {
      oldToNewInstallNames[oldInstallName] = newInstallName;
    }
    dylibs.add((dylibFile, newInstallName, frameworkDir));

    await createInfoPlist(name, resourcesDir);
  }

  for (final (File dylibFile, String newInstallName, Directory frameworkDir) in dylibs) {
    await setInstallNamesDylib(dylibFile, newInstallName, oldToNewInstallNames);
    // Do not code-sign the libraries here with identity. Code-signing
    // for bundled dylibs is done in `macos_assemble.sh embed` because the
    // "Flutter Assemble" target does not have access to the signing identity.
    if (codesignIdentity != null) {
      await codesignDylib(codesignIdentity, buildMode, frameworkDir);
    }
  }
}

/// Copies native assets for flutter tester.
///
/// For `flutter run -release` a multi-architecture solution is needed. So,
/// `lipo` is used to combine all target architectures into a single file.
///
/// The install names are set to the absolute paths from which the
/// flutter_tester executable with load them. Install names that are
/// referenced in dependent libraries are updated to match the new install name,
/// so that the referenced library can be found the dynamic linker.
///
/// Code signing is also done here.
Future<void> copyNativeCodeAssetsMacOSFlutterTester(
  Uri buildUri,
  Map<KernelAssetPath, List<FlutterCodeAsset>> assetTargetLocations,
  String? codesignIdentity,
  BuildMode buildMode,
  FileSystem fileSystem,
) async {
  assert(assetTargetLocations.isNotEmpty);

  final oldToNewInstallNames = <String, String>{};
  final dylibs = <(File, String)>[];

  for (final MapEntry<KernelAssetPath, List<FlutterCodeAsset>> assetMapping
      in assetTargetLocations.entries) {
    final Uri target = (assetMapping.key as KernelAssetAbsolutePath).uri;
    final sources = <File>[
      for (final FlutterCodeAsset source in assetMapping.value)
        fileSystem.file(source.codeAsset.file),
    ];
    final Uri targetUri = buildUri.resolveUri(target);
    final File dylibFile = fileSystem.file(targetUri);
    final Directory targetParent = dylibFile.parent;
    if (!await targetParent.exists()) {
      await targetParent.create(recursive: true);
    }
    await lipoDylibs(dylibFile, sources);
    final String newInstallName = dylibFile.path;
    final Set<String> oldInstallNames = await getInstallNamesDylib(dylibFile);
    for (final oldInstallName in oldInstallNames) {
      oldToNewInstallNames[oldInstallName] = newInstallName;
    }
    dylibs.add((dylibFile, newInstallName));
  }

  for (final (File dylibFile, String newInstallName) in dylibs) {
    await setInstallNamesDylib(dylibFile, newInstallName, oldToNewInstallNames);
    await codesignDylib(codesignIdentity, buildMode, dylibFile);
  }
}
