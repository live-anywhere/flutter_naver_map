import "dart:convert" show utf8;
import "dart:developer" show log;
import "dart:io" show Directory, File, FileSystemException;
import "dart:typed_data" show Uint8List;

import "package:crypto/crypto.dart" show sha256;
import "package:meta/meta.dart" show visibleForTesting;
import "package:path_provider/path_provider.dart" show getTemporaryDirectory;

class ImageUtil {
  // todo: maxCacheCount or maxCacheSize 도입
  static final Map<String, String> _hashPathMap = {};

  /// 테스트에서 static 캐시 상태를 초기화한다. (테스트 격리 목적)
  @visibleForTesting
  static void resetCacheForTest() {
    _hashPathMap.clear();
    _imageTempDirFuture = null;
  }

  static Future<String> saveImage(Uint8List bytes, [String? cacheKey]) async {
    final key = cacheKey ?? _generateImageHashFromBytes(bytes);
    late final String path;
    final cachedPath = _hashPathMap[key];
    // 캐시된 경로가 있어도 실제 파일이 존재하는 경우에만 재사용한다.
    // iOS는 임시 디렉터리(temporary directory)의 파일을 시스템이 임의로 정리(purge)할 수 있어,
    // in-memory 캐시에 경로가 남아있어도 파일은 사라졌을 수 있다. 이 경우 파일을 다시 생성한다.
    if (cachedPath != null && await File(cachedPath).exists()) {
      path = cachedPath;
      log("이미 저장된 이미지입니다. 저장된 path를 반환합니다. $path", name: "ImageSaveUtil");
    } else {
      path = await _makeFile(key, bytes);
      _hashPathMap[key] = path;
    }
    return path;
  }

  /* ----- Hashing ----- */

  static String _generateImageHashFromBytes(Uint8List bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /* ----- File ----- */

  static Future<String> _makeFile(String key, Uint8List bytes) async {
    final tempDirPath = await _getDir().then((d) => d.path);
    final hashedKey = sha256.convert(utf8.encode(key)).toString();
    final path = "$tempDirPath/$hashedKey.png";
    try {
      // 쓰기 직전에 부모 디렉터리 존재를 보장한다.
      // (_getDir 확인 이후에도 iOS purge가 발생할 수 있으므로 방어적으로 재생성)
      await Directory(tempDirPath).create(recursive: true);
      final file = await File(path).writeAsBytes(bytes);
      return file.path;
    } on FileSystemException catch (e) {
      log("저장중 오류가 발생했습니다. 메시지: ${e.message}", name: "ImageSaveUtil");
      rethrow;
    }
  }

  /* ----- TempDir ----- */
  // 진행 중인 초기화 Future를 캐싱한다.
  //
  // _initTempDir()는 이전 캐시 폴더를 전부 삭제하는 파괴적 로직을 포함하므로,
  // 콜드 스타트에서 여러 오버레이가 동시에 이미지를 저장하면(예: Future.wait로
  // 마커 일괄 생성) 각 호출이 _initTempDir()를 중복 실행하며 서로가 방금 만든
  // 폴더/파일을 삭제해 오버레이가 누락된다.
  // 완료된 Directory가 아니라 진행 중인 Future를 캐싱해 초기화가 단 한 번만
  // 실행되도록(single-flight) 보장한다.
  static Future<Directory>? _imageTempDirFuture;

  static Future<Directory> _getDir() async {
    // 재시도 루프: 초기화가 실패하더라도 single-flight를 유지한다.
    //
    // 실패한 공유 Future를 기다리던 여러 호출이 각각 _initTempDir()를 재실행하면
    // 파괴적 cleanup이 동시에 돌아 초기화 race가 재발한다. 따라서 실패 시
    // 실패한 Future가 아직 교체되지 않았을 때만(identical) 캐시를 비우고,
    // 루프 상단에서 공유 Future를 다시 읽어 하나의 재초기화만 공유하도록 한다.
    //
    // 영구적 실패로 무한 루프에 빠지지 않도록 재시도 횟수를 제한하고, 한도를
    // 초과하면 마지막 에러를 전파한다.
    for (var attempt = 0; ; attempt++) {
      var future = _imageTempDirFuture;
      if (future == null) {
        // 동기 구간(await 없음): 새 초기화를 생성·게시한다.
        // 동시 진입자는 다음 반복에서 이 Future를 공유하게 된다.
        future = _initTempDir();
        _imageTempDirFuture = future;
      }

      try {
        final dir = await future;
        if (await dir.exists()) return dir;
        // iOS가 임시 디렉터리(temporary directory)를 시스템 차원에서 purge하면
        // 캐시에는 경로가 남아있어도 실제 폴더는 사라진다.
        // 이 경우 동일 경로로 폴더를 재생성하여 쓰기 실패(PathNotFoundException)를 방지한다.
        return await dir.create(recursive: true);
      } catch (_) {
        // 이 Future가 실패했고 아직 다른 호출이 교체하지 않았다면 캐시에서 제거한다.
        // (다른 호출이 이미 새 Future를 게시했다면 그대로 두고 그것을 공유한다.)
        if (identical(_imageTempDirFuture, future)) _imageTempDirFuture = null;
        if (attempt >= _maxInitRetries) rethrow;
        // 루프 재진입 → 게시된 새 Future가 있으면 공유, 없으면 이 호출이 재생성.
      }
    }
  }

  /// _initTempDir 실패 시 재시도 최대 횟수(첫 시도 이후 추가 재시도 횟수).
  static const _maxInitRetries = 2;

  static Future<Directory> _initTempDir() async {
    final tempDir = await getTemporaryDirectory();
    final targetFolderDir = Directory("${tempDir.path}/$_newTempFolderPath");
    await _cleanUpLegacyTempDir(targetFolderDir);
    await _cleanUpPreviousTempDir(targetFolderDir);
    final imageTempDirParent = await targetFolderDir.create();
    final imageTempDir = await imageTempDirParent.createTemp(_newPathPrefix);
    return imageTempDir;
  }

  static Future<void> _cleanUpPreviousTempDir(Directory imgTempDir) async {
    if (!(await imgTempDir.exists())) return; // guard.

    final previousCacheFolderStream = imgTempDir.list();
    final previousCacheFolders = await previousCacheFolderStream.toList();

    for (final folder in previousCacheFolders) {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException catch (_) {
        // 이미 삭제된 경우 무시
      }
    }
  }

  static Future<void> _cleanUpLegacyTempDir(Directory newCacheFolderDir) async {
    // new version folder detected. return fast.
    if (await newCacheFolderDir.exists()) return;

    final tempDir = await getTemporaryDirectory();
    final subDirSteam = tempDir.list();

    await for (final dir in subDirSteam) {
      if (dir case Directory(:final path)) {
        final name = path.split("/").last;
        if (name.startsWith(_oldV1PathPrefix)) {
          try {
            await dir.delete(recursive: true);
          } on FileSystemException catch (_) {
            // 이미 삭제된 경우 무시
          }
        }
      }
    }
  }

  /// using <= 1.4.2
  static const _oldV1PathPrefix = "img_";

  /// currently using (1.4.3~)
  static const _newTempFolderPath = "fnm1_img";
  static const _newPathPrefix = "fnm1_img_";
}
