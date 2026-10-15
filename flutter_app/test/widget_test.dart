// SmartCane 앱 기본 테스트.
// 이전의 기본 카운터 예제 테스트는 이 앱에 맞지 않아(카운터 없음) 교체했다.
// BLE·음성 인식 플러그인은 테스트 환경에서 동작하지 않으므로 화면을 띄우지 않고
// 앱 위젯 생성만 확인한다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/main.dart';

void main() {
  test('MyApp can be constructed', () {
    const Widget app = MyApp();
    expect(app, isA<StatelessWidget>());
  });
}
