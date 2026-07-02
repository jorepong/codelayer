# 단계 7 — 메일 발송(동기) 구현 일지

## 순서와 결정
- 발송 로직을 `NotificationService`(생성)에 넣지 않고 **`NotificationDispatchService`로 분리**.
  - 이유: 단계 8에서 이 발송을 Kafka 발송 워커가 재사용해야 한다. 생성(`createForPosting`)과 발송을 한
    서비스에 묶으면 단계 8에서 발송만 떼기 어렵다. 미리 분리해 둔다.
- 발송 트리거: `JobCollectionWorker.run()`에서 `collect()`(커밋) 후 `dispatchPending()` 호출.
  - 이유(플랜): 메일은 비가역 부수효과 → **생성 트랜잭션 밖(커밋 후)**에서 발송. `collect()`의
    `@Transactional` 안에서 발송하면 롤백돼도 메일이 이미 나간다. 그래서 워커에서 collect 후 별도 호출.
- 발송기 = `NotificationMailSender` 인터페이스 + `SmtpNotificationMailSender`(JavaMailSender) 구현.
  - infra 출구를 인터페이스로 추상화. 테스트는 실제 SMTP를 못 쓰니 `@MockitoBean`으로 모의.
  - SMTP 구현에 `@Profile("!test")` — 테스트 컨텍스트에선 실제 발송 격리, mock으로 대체.
- `findByStatusOrderByCreatedAt`: **fetch join**(user·jobPosting).
  - 이유: 발송에 email·title·sourceUrl 접근 → LAZY면 N+1. fetch join으로 한 번에. `order by createdAt`은
    오래된 것부터(단계 8 릴레이 폴링과 같은 결로 미리 맞춤).
- `dispatchPending()` `@Transactional`: 조회한 PENDING 엔티티에 `markSent()`/`markFailed()` → dirty checking 저장.
  - 발송 IO가 트랜잭션 안이지만 단계 7은 동기 단순 버전. 트랜잭션 경계 정교화·중복 방지는 단계 8·9에서.

## 버린 대안
- `@TransactionalEventListener(AFTER_COMMIT)`로 생성 후 발송 이벤트: 단계 8에서 어차피 릴레이 폴링으로
  갈 거라, 지금 이벤트 리스너를 도입하면 단계 8에서 다시 걷어내야 한다. 워커에서 순차 호출이 단순.
- 발송을 Notification마다 개별 트랜잭션으로 쪼개기: 단계 7 동기 단순 버전엔 과함. 재전송/중복은 단계 9 멱등에서.

## 확인한 곳
- `User.getEmail()`, `JobPosting.getTitle()`/`getSourceUrl()` getter 존재 확인.
- `Notification.markSent()`/`markFailed()` 전이 메서드 이미 있음(단계 6 산출).
- 기존 테스트 패턴(`NotificationFlowTest`): `@SpringBootTest`·`@ActiveProfiles("test")`·`deleteAll` setUp.

## 오류·수정
- 컴파일·테스트 오류 없이 통과(BUILD SUCCESSFUL). 단 test 컨텍스트 로딩을 위해 test 소스에
  `TestNotificationMailSender`(no-op, `@Profile("test")`)를 추가 — `NotificationDispatchService`가
  `NotificationMailSender`를 주입받는데 `SmtpNotificationMailSender`가 `@Profile("!test")`라 test 프로파일에선
  빈이 비어 모든 `@SpringBootTest`가 컨텍스트 로딩에 실패하기 때문. `NotificationDispatchTest`는
  `@MockitoBean`으로 이 빈을 덮어써 발송 호출을 verify.
