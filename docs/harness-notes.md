# 하네스 후보 메모 (훅 / 스킬 / 서브에이전트)

역할 3 작업(0~7단계) 중 반복된 실수·절차·수동 검증을 적어 둔다. 기록만 하고 `.claude/` 는 건드리지 않았다.

## 훅 후보

| 트리거 | 하는 일 | 근거 |
|---|---|---|
| `scripts/*.sh`, `run-test.sh` 저장 후 (PostToolUse Edit/Write) | `shellcheck` 해당 파일 | 스크립트를 고칠 때마다 손으로 `shellcheck scripts/*.sh` 를 돌렸다. SC1091(source 경로), SC2031 오탐, 빈 배열 `${arr[@]}` 같은 것을 저장 직후 잡는 게 빠르다 |
| `compose/*.yml`, `versions.env` 저장 후 | `docker compose ... config -q` | compose 파일을 만질 때마다 `config -q` 를 수동 실행했다 |
| `monitoring/grafana/gen-dashboard.py` 저장 후 | `python3 gen-dashboard.py` 실행해 JSON 재생성 | 생성기와 JSON 이 어긋나면 안 된다. 잊기 쉽다 |
| 커밋 직전 (PreToolUse `git commit`) | `shellcheck` + `compose config -q` + `docs/progress.md` 에 해당 단계 행이 있는지 확인 | 단계 완료 = 판정 통과 + progress 갱신 + 커밋 세 가지가 항상 세트였다 |
| Bash 실행 전 | `docker system prune`, `docker volume rm bench_pgdata` 등 파괴 명령 차단 | settings.json deny 목록에 이미 일부 있음. 볼륨 삭제도 추가 후보 |

## 스킬 후보

| 이름 | 내용 |
|---|---|
| `stage-done <N>` | 그 단계의 판정 명령을 실행 → 출력 요약을 `docs/progress.md` 표에 추가 → `git commit -m "stage N: ..."`. 매 단계 똑같이 반복했다 |
| `container-flags <image>` | 새 컨테이너 플래그를 쓰기 전에 `docker run --rm <image> --help` 로 실제 플래그 이름·형식을 확인. cAdvisor(`--disable_metrics` 값 목록), postgres_exporter(`--no-collector.x` 형식) 두 번 틀렸다 |
| `docker-desktop-mount-check` | 바인드 마운트 경로가 Mac 쪽인지 VM 쪽인지 `docker run -v <path>:/x alpine ls /x` 로 먼저 확인. `/var/run` 은 Mac, `/var/lib/docker`·`/run` 은 VM 으로 매핑되는 걸 시행착오로 알았다 |
| `measure-quick` | `WARMUP_SECONDS=5 STEADY_SECONDS=10 COOLDOWN_SECONDS=0` 으로 파이프라인만 빠르게 검증. 정식 3회차(약 8분) 전에 항상 이걸 먼저 돌렸다 |
| `check-all` | `docker compose config -q` + `make lint check-resources check-targets check-dashboard` 를 한 번에. 문서의 검증 명령 세 개 + 단계별 판정을 합친 것 |

## 서브에이전트 후보

| 상황 | 이유 |
|---|---|
| `./run-test.sh <target> 3` 같은 긴 측정 (8분 이상) | 백그라운드로 돌리고 끝나면 결과 파일(`report.md`, `metrics.json`)만 읽는다. 기다리는 동안 다음 단계 파일 작업을 진행할 수 있었다 |
| 이미지 태그 존재·arm64 매니페스트·최신 안정 버전 조사 | Docker Hub API 조회는 컨텍스트만 차지한다. 결론(태그 목록)만 받으면 된다 |
| 대시보드 쿼리 검증 (`check-dashboard.sh` 결과 → 빈 패널 원인 조사) | 패널 35개 × 쿼리 81개. 지표 이름 확인은 exporter `/metrics` grep 반복이라 위임하기 좋다 |

## 반복된 실수 (재발 방지 메모)

- macOS 기본 bash 3.2: `set -u` 에서 빈 배열 `"${arr[@]}"` 가 unbound 오류. `${arr[@]+"${arr[@]}"}` 패턴 필요
- `docker buildx imagetools inspect --format` 이 구버전에서 무시됨 → 텍스트 출력 파싱. 첫 실행이 `versions.env` 를 오염시켜 손으로 되돌렸다. 파일 갱신 스크립트는 반드시 임시 파일 → 검증 → 교체 순서로
- shellcheck `source=` 디렉티브는 실행 위치에 따라 경로 해석이 달라짐 → `.shellcheckrc` 의 `source-path=SCRIPTDIR` 로 해결
- Micrometer `jvm_gc_pause_*` 는 첫 GC 이후에만 나타난다. 부하 없는 스텁에서 "빈 패널" 로 오판하지 말 것
- Prometheus 비율 쿼리는 분자 시계열이 없으면 결과가 통째로 비므로 `(... or vector(0))` 를 붙여야 0 이 나온다
