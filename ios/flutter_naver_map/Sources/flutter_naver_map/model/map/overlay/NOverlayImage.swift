import NMapsMap
import os.log

internal struct NOverlayImage {
    let path: String
    let mode: NOverlayImageMode

    var overlayImage: NMFOverlayImage {
        switch mode {
        case .file, .temp, .widget: return makeOverlayImageWithPath()
        case .asset: return makeOverlayImageWithAssetPath()
        }
    }

    private func makeOverlayImageWithPath() -> NMFOverlayImage {
        guard let scaledImage = loadScaledImage(fromFile: path) else {
            logImageLoadFailure(filePath: path)
            return NOverlayImage.fallbackOverlayImage
        }
        return NMFOverlayImage(image: scaledImage)
    }

    private func makeOverlayImageWithAssetPath() -> NMFOverlayImage {
        let key = SwiftFlutterNaverMapPlugin.getAssets(path: path)
        let assetPath = Bundle.main.path(forResource: key, ofType: nil) ?? ""
        guard let scaledImage = loadScaledImage(fromFile: assetPath) else {
            logImageLoadFailure(filePath: assetPath)
            return NOverlayImage.fallbackOverlayImage
        }
        return NMFOverlayImage(image: scaledImage, reuseIdentifier: assetPath)
    }

    /// 이미지 로드 실패(파일 없음/손상)로 투명 대체 이미지를 반환할 때 진단 로그를 남깁니다.
    ///
    /// 실패가 조용히 숨겨져 오버레이가 보이지 않는 상황을 디버깅할 수 있도록,
    /// 전체 경로 대신 파일명(마지막 경로 요소)과 mode만 기록합니다.
    private func logImageLoadFailure(filePath: String) {
        let fileName = (filePath as NSString).lastPathComponent
        let displayName = fileName.isEmpty ? "(empty)" : fileName
        os_log("NaverMap overlay image load failed, using transparent fallback. mode=%{public}@, file=%{public}@",
               type: .error, mode.rawValue, displayName)
    }

    /// 파일 경로로부터 화면 배율이 적용된 이미지를 로드합니다.
    ///
    /// 파일이 없거나(캐시 삭제 등) 손상되어 디코딩에 실패하면 `nil`을 반환합니다.
    /// 이전에는 강제 언래핑(`!`)으로 인해 이 경우 앱이 크래시했습니다.
    private func loadScaledImage(fromFile filePath: String) -> UIImage? {
        guard let image = UIImage(contentsOfFile: filePath),
              let pngData = image.pngData(),
              let scaledImage = UIImage(data: pngData, scale: DisplayUtil.scale) else {
            return nil
        }
        return scaledImage
    }

    func toMessageable() -> Dictionary<String, Any> {
        [
            "path": path,
            "mode": mode.rawValue
        ]
    }

    static func fromMessageable(_ v: Any) -> NOverlayImage {
        let d = asDict(v)
        return NOverlayImage(
                path: asString(d["path"]!),
                mode: NOverlayImageMode(rawValue: asString(d["mode"]!))!
        )
    }

    static let none = NOverlayImage(path: "", mode: .temp)

    /// 이미지 로드 실패 시 사용할 1x1 투명 대체 이미지입니다.
    ///
    /// 오버레이 이미지 생성에 실패하더라도 앱을 크래시시키지 않고, 보이지 않는
    /// 이미지로 대체하기 위한 안전장치입니다.
    private static let fallbackOverlayImage: NMFOverlayImage = {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let transparentImage = renderer.image { _ in }
        return NMFOverlayImage(image: transparentImage)
    }()
}
