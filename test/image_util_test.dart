import "dart:io" show Directory, File;
import "dart:typed_data" show Uint8List;

import "package:flutter/services.dart" show MethodChannel;
import "package:flutter_naver_map/src/util/image_util.dart";
import "package:flutter_test/flutter_test.dart";

/// ImageUtil의 임시 캐시 초기화(single-flight) 및 파일 저장 동작 회귀 테스트.
///
/// 배경: 콜드 스타트에서 여러 오버레이가 동시에 이미지를 저장하면 _getDir()가
/// _initTempDir()를 중복 실행하며 서로가 만든 캐시 폴더를 삭제해 오버레이가
/// 누락되던 race가 있었다. 초기화가 단 한 번만 실행되면 createTemp가 만드는
/// `fnm1_img_*` 하위 폴더가 정확히 1개여야 하므로, 이를 결정적으로 검증한다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel("plugins.flutter.io/path_provider");
  late Directory tempRoot;

  setUp(() {
    // static 캐시 상태를 초기화해 테스트 간 격리를 보장.
    ImageUtil.resetCacheForTest();
    // 매 테스트마다 격리된 임시 루트를 만들고 path_provider가 이를 반환하도록 목킹.
    tempRoot = Directory.systemTemp.createTempSync("fnm_image_util_test_");
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == "getTemporaryDirectory") return tempRoot.path;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Uint8List bytesOf(int seed) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  List<Directory> cacheSubFolders() {
    final base = Directory("${tempRoot.path}/fnm1_img");
    if (!base.existsSync()) return const [];
    return base.listSync().whereType<Directory>().toList();
  }

  test(
      "동시 콜드 스타트: 모든 이미지가 저장되고 캐시 폴더는 정확히 1개 (single-flight)",
      () async {
    // 서로 다른 바이트 20개를 동시에 저장 (Future.wait로 마커 일괄 생성 재현).
    final paths = await Future.wait(
      List.generate(20, (i) => ImageUtil.saveImage(bytesOf(i))),
    );

    // 1) 반환된 모든 경로의 파일이 실제로 존재해야 한다. (누락된 오버레이 = 사라진 파일)
    for (final path in paths) {
      expect(File(path).existsSync(), isTrue,
          reason: "저장된 이미지 파일이 존재해야 함: $path");
    }

    // 2) 초기화가 단 한 번만 실행됐다면 createTemp로 만든 하위 폴더는 정확히 1개.
    //    (중복 초기화 시 여러 폴더가 생성되고 일부가 삭제되어 파일이 누락된다.)
    expect(cacheSubFolders().length, 1,
        reason: "single-flight 초기화라면 캐시 하위 폴더는 1개여야 함");
  });

  test("동일 바이트 중복 저장: 캐시 히트로 같은 경로 반환", () async {
    final first = await ImageUtil.saveImage(bytesOf(100));
    final second = await ImageUtil.saveImage(bytesOf(100));
    expect(first, second);
    expect(File(first).existsSync(), isTrue);
  });

  test("캐시 파일이 외부에서 삭제되면 재생성한다", () async {
    final path = await ImageUtil.saveImage(bytesOf(200));
    expect(File(path).existsSync(), isTrue);

    // iOS temp purge를 흉내내어 파일을 삭제.
    File(path).deleteSync();
    expect(File(path).existsSync(), isFalse);

    // 동일 바이트로 다시 저장하면 stale 경로를 반환하지 않고 파일이 다시 존재해야 한다.
    final regenerated = await ImageUtil.saveImage(bytesOf(200));
    expect(File(regenerated).existsSync(), isTrue);
  });
}
