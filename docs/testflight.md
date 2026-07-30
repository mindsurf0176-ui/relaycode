# TestFlight 배포

RelayCode는 로컬 Xcode 계정 설정 없이 GitHub Actions의 Apple 자동 서명으로
아카이브를 만들고 TestFlight에 업로드할 수 있습니다. 첫 배포 전 아래의 Apple
계정 설정은 한 번 필요합니다.

## 1. Apple에 앱 등록

1. Apple Developer의 **Certificates, Identifiers & Profiles → Identifiers**에서
   명시적 App ID를 만듭니다. Bundle ID는 기본값 `com.minseo.relaycode` 또는
   본인 소유의 고유한 reverse-DNS 값을 사용합니다.
2. App Store Connect의 **Apps → + → New App**에서 같은 Bundle ID로
   `RelayCode` 앱 레코드를 만듭니다.
3. 유료 계약이나 최신 개발자 계약이 대기 중이면 먼저 동의합니다.

App Store Connect 앱 레코드는 API로 만들 수 없으므로 이 단계만 웹에서 직접
완료해야 합니다.

## 2. App Store Connect API 키 발급

1. App Store Connect의 **Users and Access → Integrations → Team Keys**로
   이동합니다.
2. API 접근 권한이 아직 없다면 Account Holder 계정으로 요청합니다.
3. TestFlight 자동 배포용 Team API Key를 생성하고 `AuthKey_*.p8`을
   다운로드합니다. 개인 키는 한 번만 다운로드할 수 있습니다.
4. 화면에 표시된 **Issuer ID**와 **Key ID**, Apple Developer 멤버십 화면의
   **Team ID**를 기록합니다.
5. 해당 사용자/역할에 Certificates, Identifiers & Profiles 접근 권한과 앱
   업로드 권한이 있는지 확인합니다.

`p8` 파일이나 그 내용을 저장소, 이슈, 채팅에 붙여 넣지 마세요.

## 3. GitHub Secrets 설정

저장소 루트에서 다음 스크립트를 실행합니다. 이 스크립트는 `testflight`
GitHub Environment를 만들고 네 값을 GitHub의 암호화된 Environment Secrets로
전송합니다.

```bash
./scripts/configure-testflight.sh
```

등록되는 Secrets:

- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`

설정 후 원본 `AuthKey_*.p8`은 암호화된 로컬 저장소에 보관하세요. 공개 저장소에
커밋하면 안 됩니다.

## 4. 첫 내부 빌드 업로드

1. GitHub 저장소의 **Actions → TestFlight → Run workflow**를 엽니다.
2. Apple에 등록한 Bundle ID와 버전을 입력합니다.
3. 첫 실물 기기 검증에서는 **내부 테스터 전용**을 켠 상태로 실행합니다.
4. 워크플로가 성공하면 App Store Connect의 **TestFlight**에서 Apple의 빌드
   처리가 끝날 때까지 기다립니다.
5. 내부 테스터 그룹에 본인 Apple ID를 추가하고 iPhone의 TestFlight 앱에서
   설치합니다.

워크플로의 빌드 번호는 GitHub run number를 사용하므로 같은 버전을 다시
업로드해도 이전 빌드와 충돌하지 않습니다. 내부 테스터 전용으로 만든 빌드는
외부 TestFlight 또는 App Store 제출용으로 전환할 수 없습니다. 외부 테스트가
필요해지면 검증 완료 후 새 빌드를 만들면서 해당 옵션을 끕니다.

워크플로가 아직 기본 브랜치에 합쳐지기 전의 기능 브랜치를 실물 기기에서 먼저
검증하려면, 해당 커밋에 `testflight-*` 형식의 태그를 푸시할 수 있습니다.
태그 빌드는 `com.minseo.relaycode`, 버전 `0.2.0`, 내부 테스터 전용 설정으로만
업로드됩니다.

## 실물 iPhone 검증 항목

- 내부 모델 약 429 MB 다운로드와 SHA-256 검증
- 비행기 모드에서 내부 모델 추론
- 첫 토큰 시간, 생성 속도, 메모리 경고, 10분 사용 시 발열
- Linux 부팅 후 `uname -a`, 파일 생성·수정·삭제
- 앱을 백그라운드로 보냈다가 돌아왔을 때 추론과 Linux 상태
- RelayCode 브리지 페어링과 재연결
