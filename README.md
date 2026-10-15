# AI Smart Cane

## 폴더 구성

- `smart_cane/`: Raspberry Pi 지팡이 코드와 기존 프로젝트 문서
- `flutter_app/`: 스마트 지팡이 Flutter 앱 (실행 전 `flutter_app/secrets.example.json`을 복사해 `secrets.json`을 만들고 API 키를 입력)

## 지팡이 실행

저장소 루트에서 다음 명령을 실행합니다.

```bash
cd smart_cane
python3 main/smartcane_full_integration.py
```

하드웨어와 설치에 관한 기존 문서는 [smart_cane/README.md](smart_cane/README.md)를 참고하세요.