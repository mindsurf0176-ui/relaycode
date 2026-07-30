import Foundation
import RelayCodeCore

enum OnDeviceInferenceEvent: Sendable {
    case token(String)
    case metrics(OnDeviceInferenceMetrics)
}

enum OnDeviceInferenceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed
    case contextCreationFailed
    case contextTooLarge
    case tokenizationFailed
    case decodeFailed
    case emptyCompletion
    case invalidOutputLimit

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "내부 모델이 메모리에 로드되지 않았습니다."
        case .modelLoadFailed:
            "내부 GGUF 모델을 불러오지 못했습니다."
        case .contextCreationFailed:
            "내부 모델의 추론 컨텍스트를 만들지 못했습니다."
        case .contextTooLarge:
            "마지막 요청이 내부 모델의 컨텍스트 한도를 초과했습니다."
        case .tokenizationFailed:
            "대화를 내부 모델 토큰으로 변환하지 못했습니다."
        case .decodeFailed:
            "내부 모델 추론 중 llama.cpp 디코딩이 실패했습니다."
        case .emptyCompletion:
            "내부 모델이 비어 있는 응답을 생성했습니다."
        case .invalidOutputLimit:
            "내부 모델의 출력 토큰 한도가 올바르지 않습니다."
        }
    }
}
