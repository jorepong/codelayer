# [2] 테스트더블 / `@MockitoBean` · 05 `@MockitoBean`과 `verify` — 덮어쓰고 심문하기

드디어 주인공이에요. 〈04〉의 no-op fake가 자리를 지키고 있었다면, 이 섹션의 `@MockitoBean`은 그 자리를 **mock으로 덮어쓰고**, 테스트 끝에서 "너 제대로 불렸어?"를 **심문**합니다. 이 두 동작 — *덮어쓰기*와 *심문* — 을 메커니즘까지 내려가 볼게요. 여기가 잡히면 이번 [2]는 사실상 끝이에요.

## 선언 — `@MockitoBean` 한 줄이 하는 일

발송 테스트의 필드 선언부터 봅시다.

`NotificationDispatchTest.java`
```java
@SpringBootTest                                                    // ❶
@ActiveProfiles("test")                                            // ❷
class NotificationDispatchTest {

    @Autowired
    NotificationDispatchService dispatchService;                   // ❸ — 진짜 서비스

    @MockitoBean
    NotificationMailSender mailSender;                             // ❹ — 이 자리를 mock으로
    ...
}
```

`❶`이 컨텍스트를 통째로 띄우고, `❷`가 test 프로파일을 켜요. 그러면 〈04〉에서 본 대로 원래는 `TestNotificationMailSender`(no-op fake)가 발송기 자리에 꽂히겠죠. 그런데 `❹`의 `@MockitoBean`이 **그 자리를 가로챕니다.**

`@MockitoBean`이 하는 일을 정확히 말하면 이래요. 스프링 테스트 컨텍스트를 띄울 때, `NotificationMailSender` 타입의 빈을 **Mockito가 만든 mock 객체로 교체(override)**하고, 그 mock을 `❹`의 필드에 주입해 줘요. 그래서 `❸`의 진짜 `dispatchService`가 발송기를 필요로 할 때, 그 안에 꽂히는 것도 **바로 이 mock**이에요. 서비스는 여전히 자기 안의 게 진짜인지 mock인지 몰라요(〈03〉의 다형성) — 그저 `NotificationMailSender`를 받아 쓸 뿐이고, `@MockitoBean`이 그 실체를 mock으로 바꿔치기한 거죠.

> **`@MockitoBean` vs `@Mock` — 왜 하필 이걸 쓰나.** 순수 Mockito의 `@Mock`은 스프링 없이 mock 객체 하나를 만들 뿐이에요. 그런데 우리 테스트는 `@SpringBootTest`로 **컨텍스트 전체를 띄운** 통합테스트라, 그 컨텍스트 *안에 있는* 발송기 빈을 바꿔야 해요. `@MockitoBean`은 정확히 그 일 — "스프링 컨텍스트의 특정 빈을 mock으로 갈아끼우기" — 을 해요. (예전 스프링 부트에선 `@MockBean`이 그 역할이었고, 최신 버전에서 `@MockitoBean`으로 이름이 바뀌었어요. 하는 일은 같아요.) 그래서 이건 "통합테스트 안에서 한 조각만 mock으로 도려내는" 도구예요 — 〈06〉에서 그 경계의 의미를 짚어요.

## mock의 본성 — "호출을 기록하는" 객체

`@MockitoBean`이 만들어 낸 mock은 어떤 객체일까요? Mockito는 런타임에 `NotificationMailSender` 인터페이스를 구현하는 **가짜 객체를 즉석에서 만들어** 내요(〈03〉에서 "mock도 인터페이스의 또 하나의 구현"이라 한 게 이거예요). 이 가짜의 `send(...)`는 기본적으로 **아무것도 안 해요** — no-op fake랑 똑같이 진짜 메일은 안 쏘죠.

그런데 fake와 **결정적으로 다른 한 가지**가 있어요. mock의 `send`는 아무것도 안 하는 대신, **자기가 불린 사실을 전부 기록**해요 — 언제, 어떤 인자로 불렸는지를. 이 "호출 장부"가 mock의 본성이에요. no-op fake는 조용히 지나가고 흔적을 안 남기지만, mock은 모든 호출을 장부에 적어 둬요. 그래서 나중에 그 장부를 펼쳐 심문할 수 있는 거죠.

## 심문 — `verify`가 장부를 펼친다

이제 실제 검증을 봅시다. 첫 테스트예요.

`NotificationDispatchTest.java`
```java
void sendOneSendsMailAndMarksSent() {
    NotificationDispatchEvent event = seedPending("alice", "https://jobs.example.com/a");  // ❺

    dispatchService.sendOne(event);                               // ❻ — 진짜 서비스 실행

    verify(mailSender).send(eq("alice@example.com"), anyString(), anyString());  // ❼
    Notification reloaded = notificationRepository.findAll().get(0);
    assertThat(reloaded.getStatus()).isEqualTo(NotificationStatus.SENT);          // ❽
}
```

흐름을 따라가 볼게요. `❺`에서 alice라는 사용자와 공고, 그리고 발송 대기(`PENDING`) 알림을 진짜 DB에 심어요. `❻`에서 **진짜 서비스**의 `sendOne`을 부르면, 그 안에서 `mailSender.send(...)`가 실행되는데 — 그 `mailSender`가 mock이라, 진짜 메일은 안 나가고 **"alice@example.com으로 send가 불렸다"가 장부에 적힙니다.**

그리고 `❼`이 심문이에요. `verify(mailSender)`는 "이 mock의 장부를 검사하겠다"는 선언이고, 이어지는 `.send(eq("alice@example.com"), anyString(), anyString())`은 **"장부에 이런 호출이 있어야 한다"**는 주장이에요. 풀어 읽으면 — "`send`가, 첫 인자는 정확히 `alice@example.com`으로(`eq`), 둘째·셋째 인자는 무엇이든(`anyString`) 불린 적이 있는가?" 있으면 통과, 없으면 테스트 실패예요.

여기서 `eq`와 `anyString`은 **인자 매처(ArgumentMatcher)**예요. 검증할 때 인자마다 "얼마나 깐깐하게 볼지"를 정하는 거죠 —
- `eq("alice@example.com")`: 이 인자는 **정확히 이 값**이어야 한다. 발송 주소는 틀리면 큰일이니 딱 맞게 검증.
- `anyString()`: 제목·본문은 **아무 문자열이든** 상관없다. 이 테스트가 확인하려는 건 "**올바른 수신자에게** 발송이 일어났나"지, 제목 문구의 정확성이 아니거든요. 그래서 거긴 느슨하게 열어 둬요.

> **왜 이렇게 인자마다 깐깐함을 나누나.** 테스트는 "이 테스트가 지키려는 약속"에만 깐깐하고 나머지엔 느슨해야 해요. 여기서 지키는 약속은 "PENDING 알림의 **주인에게** 메일이 간다"예요. 그래서 수신자(`eq`)만 못 박고, 제목·본문(`anyString`)은 풀어 둔 거죠. 만약 제목까지 `eq`로 박으면, 나중에 제목 문구를 살짝 고칠 때마다 이 테스트가 깨져요 — 약속과 무관한 이유로요. **검증의 깐깐함을 약속에 맞추는 것**, 이게 좋은 mock 검증의 감각이에요.

마지막으로 `❽`은 mock이 아니라 **진짜 DB 상태**를 확인해요 — 발송 뒤 알림이 `SENT`로 전이됐는지. 여기서 이번 [2]와 다음 개념([1]·[U])이 어떻게 나뉘는지 슬쩍 보여요. `❼`은 "**바깥으로 나가는 상호작용**(발송 호출)"을 mock으로 검증하고, `❽`은 "**안에 남는 상태**(DB의 status)"를 진짜로 검증해요. 나가는 건 mock, 남는 건 실물 — 이 이중 잠금은 "코드가 보고하는 값과 저장소의 실제 상태를 모두 단언한다"는 그 감각이에요.

## 횟수까지 심문 — `times(1)`

mock의 장부는 "불렸나"뿐 아니라 "**몇 번** 불렸나"까지 기록해요. 둘째 테스트가 그걸 써요.

`NotificationDispatchTest.java`
```java
void sendOneIsIdempotentAcrossRedelivery() {
    NotificationDispatchEvent event = seedPending("bob", "https://jobs.example.com/b");

    dispatchService.sendOne(event);                              // ❾ — 첫 번째
    dispatchService.sendOne(event);                              // ❿ — 두 번째(같은 이벤트)

    verify(mailSender, times(1)).send(eq("bob@example.com"), anyString(), anyString());  // ⓫
}
```

`❾`·`❿`에서 **같은 발송을 두 번** 부르는데, `⓫`은 `times(1)` — "메일 발송(`send`)은 장부에 **딱 한 번만** 있어야 한다"고 심문해요. 두 번 불렀는데 발송은 한 번? 그 사이 어딘가가 두 번째를 걸러냈다는 뜻이죠. (그 "거르는 장치"가 바로 9단계 멱등 관문인데 — 여기선 스포일러니 넘어가요. 지금 눈에 담을 건 **"mock으로 호출 횟수를 검증할 수 있다"**는 그 능력이에요.)

이게 진짜 발송기로는 절대 못 하던 검증이에요. "메일이 정확히 한 번 나갔다"를 진짜 발송으로 어떻게 세겠어요? mock의 장부라서, "몇 번"이 손에 잡히는 숫자가 됩니다.

> **참고 — 인자 매처를 섞을 땐 규칙이 있다.** `verify` 안에서 인자 하나라도 `eq`·`anyString` 같은 매처를 쓰면, **나머지 인자도 전부 매처로** 맞춰야 해요(Mockito 규칙). 그래서 위에서 `eq(...)` 하나 쓴 김에 나머지도 `anyString()` 매처로 통일한 거예요 — 하나는 매처, 하나는 생값(`"..."`)으로 섞으면 Mockito가 에러를 냅니다. 지금 깊이 팔 건 아니고, "매처는 다 매처로 통일한다"만 기억해 두면 나중에 안 헤매요.

여기까지가 mock의 두 얼굴이에요 — 컨텍스트에선 **자리를 덮어쓰고**(`@MockitoBean`), 검증에선 **장부를 펼쳐 심문한다**(`verify`·`times`). 이제 마지막 한 조각이 남았어요. fake도 봤고 mock도 봤으니, **왜 이 프로젝트엔 둘이 같이 사는지**, 그리고 통합테스트에서 **무엇을 진짜로 두고 무엇을 가짜로 바꿀지**의 판단 기준 — 그리고 이번 단계를 어디서 멈춰도 되는지의 충분선을 다음 〈06〉에서 맞출게요.
