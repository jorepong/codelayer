# [2] 테스트더블 / `@MockitoBean` · 04 `TestNotificationMailSender` — 컨텍스트를 살리는 fake

이제 대역이 실제로 문으로 들어오는 걸 봅니다. 조용한 쪽부터예요 — 아무것도 안 하는 no-op fake, `TestNotificationMailSender`. 그런데 이 대역은 "왜 있는지"가 처음엔 아리송해요. **아무 일도 안 하는데 왜 굳이 만들어 뒀을까?** 여기엔 당신이 예상하기 어려운, 스프링 특유의 이유가 하나 숨어 있어요. 그걸 파헤치는 게 이 섹션이에요.

## 먼저 코드 — 프로파일로 갈라진 두 발송기

발송기 구현이 둘인데, 각각 **정반대의 프로파일 조건**을 달고 있어요.

`SmtpNotificationMailSender.java`
```java
@Component
@Profile("!test")                                                  // ❶ — test가 "아닐" 때만
public class SmtpNotificationMailSender implements NotificationMailSender {
    private final JavaMailSender mailSender;
    ...
    public void send(String to, String subject, String body) {
        SimpleMailMessage message = new SimpleMailMessage();
        message.setTo(to);  message.setSubject(subject);  message.setText(body);
        mailSender.send(message);                                   // ❷ — 진짜 SMTP 발송
    }
}
```

`TestNotificationMailSender.java`
```java
@Component
@Profile("test")                                                   // ❸ — test일 때만
public class TestNotificationMailSender implements NotificationMailSender {
    public void send(String to, String subject, String body) {
        // no-op                                                    // ❹ — 아무것도 안 함
    }
}
```

`❶`의 `@Profile("!test")`는 "**test가 아닌** 프로파일에서만 이 빈을 등록하라"는 뜻이에요(느낌표가 부정). 반대로 `❸`의 `@Profile("test")`는 "test 프로파일에서만 등록하라". 두 조건이 서로 배타적이라, **어느 프로파일에서든 발송기 빈은 정확히 하나만 존재**해요 — 운영에선 진짜(`❷`), 테스트에선 no-op(`❹`).

`❶`이 test에서 진짜 발송기를 빼는 건 〈01〉의 이유로 당연해요(테스트가 진짜 메일 쏘면 안 되니까). 그런데 이상한 건 `❸`이에요. **test에서 진짜를 뺐으면 그냥 발송기가 없으면 되지, 왜 아무것도 안 하는 가짜를 굳이 그 자리에 채워 넣었을까요?** `@MockitoBean`으로 어차피 mock을 꽂을 거면서요.

## 이 질문에 답하려면 — '컴파일'이 아니라 '컨텍스트 로딩'을 봐야 한다

여기가 이 섹션의 결정적 지점이에요. 답을 단정하지 않고 메커니즘까지 내려가 볼게요.

당신이 자바에 익숙하니 자연스럽게 "빈이 없으면 컴파일 에러 나나?" 싶을 수 있는데, **아니에요.** 컴파일은 멀쩡히 통과해요 — `NotificationDispatchService`는 `NotificationMailSender`(인터페이스 타입)를 참조할 뿐이고, 그 인터페이스는 존재하니까요. 컴파일러는 "이 인터페이스를 구현한 빈이 런타임에 실제로 있는지"는 따지지 않아요. 타입만 맞으면 통과입니다.

문제는 **런타임의 컨텍스트 로딩 때**에 터져요. `@SpringBootTest`가 애플리케이션 컨텍스트를 띄우는 과정을 떠올려 보세요. 스프링은 빈들을 만들면서 **의존성을 채워 넣어야** 해요. `NotificationDispatchService`를 만들려면 그 생성자를 불러야 하는데 —

```java
public NotificationDispatchService(..., NotificationMailSender mailSender, ...) {  // ❺
```

`❺`에서 스프링은 "`NotificationMailSender` 타입의 빈을 하나 찾아서 여기 꽂아라"라는 요구를 받아요. 그런데 만약 test 프로파일에서 **진짜도 빠지고(`@Profile("!test")`) 대역도 없다면**, 그 타입의 빈이 컨텍스트에 **하나도 없어요.** 스프링은 꽂을 게 없으니 이런 에러를 내며 컨텍스트 로딩에 실패합니다 — `NoSuchBeanDefinitionException: No qualifying bean of type 'NotificationMailSender'`.

그리고 여기서 파장이 커져요. 컨텍스트 로딩이 실패하면 그 컨텍스트를 쓰는 **모든 `@SpringBootTest`가 시작도 못 하고 무너져요.** 발송과 아무 상관 없는 구독 테스트, 수집 테스트까지 전부요. 실제로 이 프로젝트의 구현 일지에도 그 사고가 적혀 있어요 — no-op 대역을 안 뒀더니 "test 프로파일에선 빈이 비어 모든 `@SpringBootTest`가 컨텍스트 로딩에 실패"했다고요.

## 그래서 fake가 하는 진짜 일 — "빈자리 메우기"

이제 `TestNotificationMailSender`의 존재 이유가 선명해져요. 이 no-op 대역은 **발송을 하려고 있는 게 아니에요.** `NotificationMailSender` 타입의 빈이 test 컨텍스트에 **적어도 하나는 존재하게** 만들어서, `❺`의 주입 요구를 충족시키고 **컨텍스트가 무사히 뜨게** 하려고 있는 거예요. 하는 일이 `// no-op`인 건 결함이 아니라 **정확히 그 역할에 맞는 설계**예요 — 자리는 채우되 아무 부작용도 없어야 하니까.

> **왜 하필 이 대역이 "기본값"인가.** 발송 테스트(`NotificationDispatchTest`)는 뒤에서 `@MockitoBean`으로 이 자리를 mock으로 덮어쓸 거예요. 하지만 **발송기를 건드리지 않는 다른 테스트들**(구독·수집 등)은 mock을 꽂지 않죠. 그들에게도 컨텍스트는 떠야 하니까, 그때 이 no-op fake가 조용히 그 자리를 지킵니다. 즉 이 fake는 "발송을 신경 안 쓰는 모든 테스트를 위한 **바닥 대역**"이에요. 발송을 검증하려는 테스트만 그 위에 mock을 얹고요. 이 "바닥 fake + 필요할 때만 얹는 mock" 구도가 왜 좋은 분업인지는 〈06〉에서 마무리해요.

## `@Profile`이 〈03〉의 DI와 만나는 자리

한 겹 더 깊이 보면, 이건 〈03〉에서 본 **DI의 "누구를 꽂을지 결정"**이 실제로 작동하는 모습이에요. `@Profile`은 그 결정에 **조건**을 거는 스위치예요 — "이 프로파일일 때만 이 빈을 후보로 올려라." 스프링은 활성 프로파일(`@ActiveProfiles("test")`)을 보고 후보를 추린 뒤, `NotificationMailSender` 타입 요구에 맞는 빈을 꽂아요. `!test`와 `test`가 배타적이라 **후보가 언제나 정확히 하나**가 되게 설계한 거죠. 후보가 둘이면(둘 다 조건 만족) 스프링은 "누굴 꽂아야 할지 모르겠다"며 또 실패하고, 후보가 영이면 방금 본 대로 실패해요. 프로파일 조건을 배타적으로 그은 건 이 **"정확히 하나"**를 지키기 위한 판단이에요.

여기까지가 조용한 대역의 이야기예요. 자리를 채워 컨텍스트를 살리는, 겉보기엔 심심하지만 없으면 전부 무너지는 fake. 이제 진짜 주인공으로 갑니다 — 그 fake가 지키던 자리를 **덮어쓰고**, 발송이 제대로 일어났는지 **심문**하는 mock. 다음 〈05 `@MockitoBean`과 `verify`〉예요.
