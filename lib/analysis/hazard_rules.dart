import 'hazard.dart';

/// 위험 종류 하나의 규칙: AI는 [key]만 고르고, 등급([severity])은 이 표가 정함.
class HazardRule {
  const HazardRule(this.key, this.label, this.severity, this.definition,
      [this.basis = const []]);

  /// AI가 답으로 주는 값(영문). 저장 기록에도 이 값이 남음
  final String key;

  /// 화면·기록에 보이는 이름
  final String label;

  /// 이 종류의 등급. 사진마다 AI가 정하지 않고 항상 같음
  final Severity severity;

  /// AI에게 주는 설명: 사진에서 무엇이 보이면 이 종류인가
  final String definition;

  /// 관련 법령·기준(참고용 — 법 위반 여부를 판정하는 것이 아님).
  /// 2026-11-10 국가법령정보센터(law.go.kr) 현행 본문·별표에서 조문을 직접 확인한 것만 적음. 출처·판본은 APP_OVERVIEW.md 2-4
  final List<String> basis;
}

// 자주 나오는 법령 이름(표가 길어지지 않게)
const _osh = '산업안전보건기준에 관한 규칙';
const _mech = '기계설비 유지관리기준 별지 제2호서식(유지관리 점검표)';
const _elecTech = '전기설비기술기준';
const _elecInspect = '전기설비 검사 및 점검의 방법·절차 등에 관한 고시 별표 7(정기검사 외관 항목)';
const _fireCheck = '소방시설 자체점검사항 등에 관한 고시 별지 제4호서식(점검표)';

/// 위험 판단 규칙표(2026-11-10). 강사 피드백 "LLM 의존도 완화·평가 기준 보완"에 대한 답:
/// - AI(LLM)는 사진에서 위험을 찾아 **종류만** 고름(정해진 목록 중 하나)
/// - **등급은 이 표가 정함** → 같은 종류는 언제나 같은 등급
/// - 여러 위험이 함께 보일 때 올리는 규칙도 앱이 적용([apply])
///
/// 종류와 관련 기준은 한국 법령·고시의 점검 항목에서 가져옴(기계설비·전기·소방·산업안전보건).
/// 등급 3단계는 법령이 정한 것이 아님: 법정 판정은 적합/조치필요(기계설비), 부적합/조언(전기), 중대위반사항/그 밖의 불량(소방)처럼
/// 두 갈래뿐이라, 「사업장 위험성평가에 관한 지침」(고용노동부 고시)이 허용하는 **위험성 수준 3단계 판단법** 방식으로 우리가 정함.
///   위험(상) = 지금 바로 사람이 다치거나 불이 날 수 있음 → 즉시 조치·접근 통제
///   주의(중) = 방치하면 사고로 이어짐 → 계획을 세워 조치
///   관찰(하) = 지금은 위험하지 않음 → 기록하고 다음 점검 때 확인
/// 그 지침은 판단 기준이 "법에서 정한 기준 이상"이어야 한다고 하므로, 법령이 직접 요구하는 방호·확보·표지가
/// 빠진 상태는 관찰(하)에 두지 않고 위험이나 주의로 둠.
abstract final class HazardRules {
  static const all = <HazardRule>[
    // ── 전기 ──
    HazardRule(
        'live_part_exposed',
        '충전부 노출',
        Severity.high,
        '분전반·배전반·접속함의 보호판이나 덮개가 빠져 내부 단자·모선·전선 접속부(전기가 흐르는 금속)가 드러남',
        ['$_osh 제301조(충전부 방호)', '$_elecTech 제53조', '한국전기설비규정(KEC) 211.7.2']),
    HazardRule(
        'panel_door_open',
        '분전반 문 열림',
        Severity.medium,
        '분전반·배전반·제어반의 문이 열린 채 방치됨(안쪽 보호판은 그대로여서 단자·모선은 안 보임)',
        ['$_osh 제301조(문·패널은 견고하게 고정)', 'KEC 211.7.2']),
    HazardRule(
        'wire_damaged',
        '전선 피복 손상',
        Severity.high,
        '전선 피복이 벗겨지거나 찢어져 속 구리선이 보임, 테이프로 임시로 이은 전선',
        ['$_osh 제313조(배선 등의 절연피복)', '$_elecTech 제50조']),
    HazardRule(
        'water_near_electrical',
        '전기설비 주변 물기',
        Severity.high,
        '분전반·전동기·전선·콘센트 같은 전기설비에 물이 닿거나, 그 바로 아래·옆에 누수·물고임이 있음',
        ['$_osh 제304조(누전차단기)·제314조(습윤한 장소)', _elecInspect, 'KEC 232.84']),
    HazardRule(
        'smoke_or_burn',
        '연기·그을음·과열 흔적',
        Severity.high,
        '연기, 불꽃, 그을음, 탄 자국, 전기 접속부의 변색·녹아내린 흔적',
        [
          '소방기본법 제19조·제20조(화재 통지·관계인 조치)',
          '$_elecTech 제8조·제9조',
          '전기안전관리자의 직무에 관한 고시 별지 제7호서식(열화상 판정)'
        ]),
    HazardRule(
        'panel_obstructed',
        '분전반 앞 적치',
        Severity.medium,
        '분전반·배전반·제어반 앞을 물건이 막아 문을 열거나 조작하기 어려움',
        ['$_osh 제310조(작업공간 폭 70cm 이상)', _elecInspect, 'KEC 232.84']),
    HazardRule(
        'wiring_untidy',
        '정리 안 된 배선',
        Severity.low,
        '엉키거나 늘어진 배선, 케이블트레이 밖으로 처진 케이블(피복 손상은 없고 통로 바닥도 아님)',
        ['$_elecTech 제50조(배선의 시설)', 'KEC 232.41.1(케이블트레이)']),
    // ── 기계설비 ──
    HazardRule(
        'rotating_unguarded',
        '회전체 덮개 없음',
        Severity.high,
        '벨트·풀리·커플링·회전축·팬 날개가 방호덮개 없이 드러남',
        ['$_osh 제87조(원동기·회전축 등의 위험 방지)', '산업안전보건법 제80조', _mech]),
    HazardRule(
        'gas_leak_sign',
        '가스 누설 징후',
        Severity.high,
        '가스 배관·밸브·호스의 손상, 가스누설경보기 경보 표시 등 가스가 새는 징후',
        ['도시가스사업법 시행규칙 별표 7', '$_osh 제232조·제296조', '산업안전보건법 제51조(작업중지)']),
    HazardRule(
        'flooding',
        '침수',
        Severity.high,
        '방이나 통로 바닥의 대부분이 물에 잠김, 물이 계속 쏟아져 차오르는 중',
        ['$_osh 제3조(전도의 방지)·제304조(누전차단기)', _elecInspect, _mech]),
    HazardRule(
        'leak',
        '누수·누유',
        Severity.medium,
        '배관·밸브·펌프·탱크에서 새는 물·기름, 바닥 일부의 물고임(전기설비 주변이 아니고 침수도 아닐 때)',
        ['기계설비 유지관리기준 제9조', _mech, '$_osh 제3조(전도의 방지)']),
    HazardRule(
        'corrosion',
        '배관·설비 부식',
        Severity.medium,
        '녹이 깊어 표면이 들뜨거나 떨어져 나감, 구멍·누설 흔적, 지지대·볼트의 심한 부식',
        [_mech, '기계설비 유지관리기준 별지 제3호서식(성능점검표)', '기계설비법 제17조']),
    HazardRule(
        'gauge_abnormal',
        '계기 이상',
        Severity.medium,
        '압력계·온도계 바늘이 빨간 구간이나 눈금 밖을 가리킴, 계기 유리 파손·판독 불가',
        [_mech, '$_osh 제116조(압력방출장치)·제119조']),
    HazardRule('minor_rust', '경미한 녹·얼룩', Severity.low,
        '표면 변색, 얇은 녹, 물 얼룩(들뜸·구멍·누설 흔적 없음)', [_mech]),
    HazardRule('insulation_damaged', '보온재 훼손', Severity.low,
        '배관·덕트 보온재가 벗겨지거나 찢어지거나 젖음', [_mech, '기계설비 기술기준 별표 10']),
    // ── 소방 ──
    HazardRule(
        'extinguisher_blocked',
        '소화기·소화전 이상',
        Severity.medium,
        '소화기·소화전 앞을 물건이 막음, 소화기가 넘어져 있거나 제자리에 없음, 소화기 압력계가 녹색 범위 밖이거나 손상',
        [
          '소화기구 화재안전성능기준(NFPC 101) 제4조',
          '옥내소화전설비 화재안전성능기준(NFPC 102) 제7조',
          _fireCheck
        ]),
    HazardRule(
        'evacuation_blocked',
        '통로·방화문 막힘',
        Severity.medium,
        '통로·계단·출입구·방화문 앞에 물건이 쌓여 지나가기 어려움, 방화문을 열어 고정해 둠',
        [
          '소방시설 설치 및 관리에 관한 법률 제16조',
          '$_osh 제22조(통로의 설치)',
          '건축물의 피난·방화구조 등의 기준에 관한 규칙 제14조'
        ]),
    HazardRule(
        'combustibles_stored',
        '가연물 적치',
        Severity.medium,
        '기계실·전기실에 박스·페인트·기름통·걸레 등 타기 쉬운 물건을 쌓아 둠(창고처럼 사용)',
        [
          '화재의 예방 및 안전관리에 관한 법률 제17조',
          '$_osh 제4조(작업장의 청결)·제238조',
          '소방시설 자체점검사항 등에 관한 고시 별지 제6호서식'
        ]),
    HazardRule(
        'exit_light_off',
        '유도등·비상조명 이상',
        Severity.medium,
        '피난구 유도등·비상조명등이 꺼져 있거나 깨짐, 물건에 가려 안 보임',
        ['유도등 및 유도표지의 화재안전성능기준(NFPC 303) 제10조', _fireCheck]),
    // ── 작업 환경 ──
    HazardRule(
        'opening_unguarded',
        '개구부·피트 덮개 없음',
        Severity.high,
        '바닥의 개구부·피트·맨홀이 덮개나 난간 없이 열려 있어 빠지거나 떨어질 수 있음',
        ['$_osh 제43조(개구부 등의 방호 조치)', _mech]),
    HazardRule(
        'floor_obstacle',
        '바닥 장애물',
        Severity.medium,
        '바닥·통로에 널린 부품·공구·자재·호스·전선(걸려 넘어질 수 있음), 미끄러운 바닥',
        ['$_osh 제3조(전도의 방지)·제22조(통로의 설치)·제315조(통로바닥 전선)']),
    HazardRule('no_ppe', '보호구 미착용', Severity.medium,
        '작업 중인 사람이 안전모·장갑 등 보호구를 쓰지 않음', ['$_osh 제32조(보호구의 지급 등)']),
    HazardRule(
        'sign_missing',
        '안전표지 훼손',
        Severity.medium,
        '위험 표지·출입금지 표지·소화기 표지가 없거나 떨어졌거나 읽을 수 없음',
        [
          '전기안전관리자의 직무에 관한 고시 제17조(위험표시)',
          '$_elecTech 제21조',
          '소화기구 화재안전기술기준(NFTC 101) 2.1.1.6'
        ]),
    HazardRule('structure_damage', '균열·파손', Severity.low,
        '벽·바닥·받침대·설비 외함의 균열, 깨짐, 변형', [_mech]),
    // ── 그 밖 ──
    HazardRule('other', '기타 위험', Severity.medium,
        '위 목록에 맞는 것이 없을 때만. 등급은 주의로 두고 기사가 판단'),
  ];

  static final _byKey = {for (final r in all) r.key: r};

  /// AI 답 형식의 category에 넣을 수 있는 값
  static List<String> get keys => [for (final r in all) r.key];

  static HazardRule? of(String? key) => _byKey[key];

  /// 같은 사진에 이 종류가 있으면 "전기 위험이 함께 있다"고 봄([apply]의 올림 규칙)
  static const electricalHazards = {'live_part_exposed', 'wire_damaged'};

  /// 올림 규칙으로 등급이 바뀌었을 때 기록에 남기는 설명
  static const leakWithElectricalNote = '같은 사진에 충전부 노출·전선 손상이 있어 위험으로 올림';

  /// AI에게 주는 종류 목록(지시문에 그대로 들어감). 등급은 알려 주지 않음 — AI는 종류만 고름
  static String get promptList =>
      all.map((r) => '- ${r.key}(${r.label}): ${r.definition}').join('\n');

  /// AI가 준 위험 목록(JSON)에 규칙표를 적용해 등급을 정함.
  /// 1) category가 목록에 있으면 그 종류의 등급(AI가 severity를 줬어도 무시)
  /// 2) 올림 규칙: 누수·누유(leak)가 충전부 노출·전선 손상과 같은 사진에 있으면 위험으로
  /// category가 없거나 모르는 값이면(예전 형식) 건드리지 않음
  static List<Map<String, dynamic>> apply(List<Map<String, dynamic>> hazards) {
    final electrical =
        hazards.any((h) => electricalHazards.contains(h['category']));
    return [
      for (final h in hazards)
        switch (of(h['category'] as String?)) {
          null => h,
          final r when r.key == 'leak' && electrical => {
              ...h,
              'severity': Severity.high.name,
              'rule_note': leakWithElectricalNote,
            },
          final r => {...h, 'severity': r.severity.name},
        }
    ];
  }
}
