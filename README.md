# CodeLayer

> 실무 코드 기반 선택형 학습 프레임워크 — 개발 레이어와 학습 레이어를 분리합니다.

CodeLayer는 "만들면서 배우되, 만드는 일과 배우는 일을 섞지 않는" 학습 방식입니다.
AI 어시스턴트(Claude Code 등)와 함께 실무 수준의 프로젝트를 진행하면서, 각 구현 단계가 끝날 때마다 그 코드에서 학습할 개념을 **직접 골라** 깊이 있게 학습합니다.

이 저장소는 CodeLayer의 **순수 골격(템플릿)** 입니다. 학습하고 싶은 프로젝트에 이 구조를 복사해 넣으면, AI가 `INSTRUCTIONS.md`의 규칙에 따라 학습 진행자(튜터) 역할을 시작합니다.

---

## 왜 CodeLayer인가

일반적인 AI 페어 프로그래밍은 두 가지를 동시에 합니다 — 코드를 만들고, 그 자리에서 설명합니다. 이때 설명은 흐름을 끊지 않으려고 짧아지고, 코드는 학습자 수준에 맞춰 단순해지기 쉽습니다. 결과적으로 **실무 코드도, 깊은 학습도 어중간해집니다.**

CodeLayer는 이 둘을 레이어로 분리합니다.

| | 개발 레이어 | 학습 레이어 |
|---|---|---|
| 언제 | 구현 중 | 단계 완료 후 |
| 코드 수준 | 항상 실무 수준 | (원본 코드를 읽기만 함) |
| 설명 | 하지 않음 (주석 최소화) | 1대1 튜터처럼 깊이 있게 |
| 결과물 | 동작하는 프로젝트 | 단계별 학습 문서 |

구현 중에는 설명하지 않으므로 코드 품질을 타협하지 않습니다. 학습은 단계가 끝난 뒤 별도로, 학습자가 고른 개념만 충분한 깊이로 진행합니다.

---

## 핵심 동작 흐름

```
①  플랜 작성        .plan/current.md 에 프로젝트 기획 + 구현 단계 작성 → 승인
        │
②  단계 구현        실무 수준 코드 작성 (설명 없음)
        │
③  학습 포인트 추출   단계 완료 시 overview/step-N.md 생성
        │           → 그 단계 코드에서 배울 개념들을 점수와 함께 나열
        │
④  개념 선택        학습자가 학습할 포인트 번호를 고름
        │
⑤  학습 문서 생성    learn/.../01-...md, 02-...md ... ("다음"으로 한 장씩 진행)
        │           Why First → 콜아웃(❶❷❸) 기반 깊은 서술
        │
⑥  이해도 평가      exercises/ 에 개념 질문(Q)·구현 과제(Ex) 생성 (선택)
        │
⑦  프로필 갱신       learner_profile/PROFILE.md 에 학습자 역량 반영
        │
        └──→ 다음 단계로
```

이 모든 절차의 정확한 규칙은 [`.codelayer/INSTRUCTIONS.md`](.codelayer/INSTRUCTIONS.md)에 정의되어 있습니다. AI는 매 세션 시작 시 이 파일과 프로필, 플랜을 읽고 동작합니다.

---

## 디렉토리 구조

```
.
├── CLAUDE.md                       ← AI에게 "이 프로젝트는 CodeLayer로 동작한다"고 알리는 진입점
├── .codelayer/
│   ├── INSTRUCTIONS.md             ← CodeLayer 작동 규칙 전문 (프레임워크 본체)
│   ├── learner_profile/
│   │   └── PROFILE.md              ← 학습자 프로필 / 지식 베이스 (사람에 대한 기록)
│   ├── overview/                   ← 단계별 학습 포인트 개요 (단계 완료 시 생성)
│   └── learn/                      ← 개념별 학습 설명 문서 (개념 선택 시 생성)
└── .plan/
    ├── current.md                  ← 현재 진행 중인 플랜 (프로젝트 시작 시 생성)
    └── archive/                    ← 완료된 플랜 보관소
```

빈 디렉토리(`overview/`, `learn/`, `.plan/archive/`)는 `.gitkeep`으로 유지됩니다. 프로젝트를 진행하면 이 안에 학습 자료가 쌓입니다.

`PROFILE.md`는 특정 프로젝트에도 CodeLayer 구조에도 종속되지 않는 **사람 자체에 대한 문서**입니다. 처음에는 빈 템플릿이며, 온보딩과 학습을 거치며 채워집니다. 같은 학습자가 새 프로젝트를 시작할 때 이 파일을 가져오면 이전까지 쌓인 역량 위에서 학습을 이어갈 수 있습니다.

---

## 사용법

### 1. 새 프로젝트에 CodeLayer 얹기

학습하고 싶은 프로젝트 디렉토리에서 이 저장소의 구조만 가져옵니다.

```bash
# 방법 A — 빈 새 프로젝트로 시작
git clone https://github.com/jorepong/codelayer.git my-learning-project
cd my-learning-project
rm -rf .git && git init        # 학습 프로젝트만의 새 git 히스토리로 시작

# 방법 B — 이미 있는 프로젝트에 구조만 복사
cd /path/to/existing-project
cp -R /path/to/codelayer/{CLAUDE.md,.codelayer,.plan} .
```

### 2. 학습 시작

프로젝트 루트에서 Claude Code를 엽니다. AI는 `CLAUDE.md`를 통해 `INSTRUCTIONS.md`를 읽고 CodeLayer 진행자가 됩니다.

- `PROFILE.md`가 비어 있으면 **온보딩**(주력 스택·경력·학습 목표 질문)부터 시작합니다.
- 이후 "무엇을 만들고 싶은지" 말하면 AI가 `.plan/current.md`에 플랜을 작성하고, 승인 후 구현 → 학습 사이클을 반복합니다.

### 3. 진행 방식

- 단계가 끝나면 AI가 `overview/step-N-단계명.md`를 만들고 학습 포인트를 알려줍니다.
- 학습하고 싶은 **포인트 번호**를 고르면 `learn/` 아래에 학습 문서가 한 장씩 생성됩니다. **"다음"** 으로 다음 장, **"계속"** 으로 끊긴 설명을 잇습니다.
- 원하면 이해도 평가(`exercises/`)를 진행하고, AI가 `PROFILE.md`를 갱신합니다.

> Claude Code용 슬래시 커맨드(`/cl-init`, `/cl-plan`, `/cl-learn`, `/cl-profile`, `/cl-done`)가 설치되어 있다면 각 단계를 명령으로도 호출할 수 있습니다. 없어도 `INSTRUCTIONS.md` 규칙만으로 동작합니다.

---

## 템플릿 업데이트 관리

이 저장소는 CodeLayer의 **원본(upstream)** 입니다. 규칙(`INSTRUCTIONS.md`)이나 구조를 개선하면 여기에 커밋합니다. 각 학습 프로젝트는 이 원본에서 파생된 사본이므로, 개선 사항을 받아오려면 다음 방식 중 하나를 씁니다.

**방식 1 — 파일만 덮어쓰기 (간단)**

규칙 파일만 최신으로 교체합니다. 학습 자료(`overview/`, `learn/`, `PROFILE.md`)는 건드리지 않습니다.

```bash
cd /path/to/learning-project
curl -fsSL https://raw.githubusercontent.com/jorepong/codelayer/main/.codelayer/INSTRUCTIONS.md \
  -o .codelayer/INSTRUCTIONS.md
```

**방식 2 — upstream 리모트로 동기화 (권장)**

학습 프로젝트에서 이 저장소를 `upstream`으로 등록해두고, 필요할 때 규칙 파일만 가져옵니다.

```bash
git remote add upstream https://github.com/jorepong/codelayer.git
git fetch upstream
git checkout upstream/main -- .codelayer/INSTRUCTIONS.md CLAUDE.md
```

> 핵심 원칙: **업데이트는 한 방향(원본 → 사본)으로만 흐릅니다.** 학습 프로젝트에서 쌓인 `overview/`·`learn/`·`PROFILE.md`는 그 프로젝트의 자산이므로 절대 원본으로 되돌려 커밋하지 않습니다. 원본에는 규칙·구조·빈 템플릿만 둡니다.

---

## 구성 파일 요약

| 파일 | 역할 | 누가 채우나 |
|------|------|------------|
| `CLAUDE.md` | AI 진입점. INSTRUCTIONS를 읽으라고 지시 | 고정 |
| `.codelayer/INSTRUCTIONS.md` | 작동 규칙 전문 | 프레임워크 (여기서 관리) |
| `.codelayer/learner_profile/PROFILE.md` | 학습자 역량 기록 | AI (학습 진행하며 갱신) |
| `.codelayer/overview/` | 단계별 학습 포인트 개요 | AI (단계 완료 시) |
| `.codelayer/learn/` | 개념별 학습 문서 | AI (개념 선택 시) |
| `.plan/current.md` | 현재 플랜 | AI (프로젝트 시작 시) |

---

## 라이선스

개인 학습 도구입니다. 자유롭게 복제·수정해 사용하세요.
