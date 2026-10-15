# 로컬 채팅·임베딩 서버 실행

프로젝트 폴더에서 시작합니다. Python 3.10 이상, 표준 라이브러리만 사용합니다.

```sh
python3 start.py
```

OS를 감지하고 채팅·임베딩 모델 후보를 따로 보여줍니다. 각 목록에서 번호를 선택하면 채팅 서버부터 순서대로 시작합니다. `/health`, `/v1/models`, 실제 채팅·임베딩 요청이 성공한 뒤 선택한 모델 ID와 포트가 들어간 API 예제를 출력합니다. 준비 확인에도 짧은 실제 추론 요청이 사용됩니다. 터미널을 유지하며, **Ctrl-C로 이 실행기가 시작한 서버만 종료**합니다.

어느 작업 디렉터리에서든 `python3 /프로젝트/절대경로/start.py`로 실행할 수 있습니다. `.env` 위치는 항상 스크립트 옆 `docker/vllm/.env`입니다. `.env`는 읽기만 하고 자식 프로세스 환경에 적용합니다. 셸에 이미 설정된 `VLLM_API_KEY`가 있으면 그 값이 우선합니다.

## 실행 전 확인

```sh
python3 start.py --list-only
python3 start.py --dry-run
python3 start.py --os macos --backend metal
python3 start.py --cache-dir /모델캐시/hub --model-dir /추가/모델폴더 --list-only
```

`--cache-dir`는 Hugging Face **hub 디렉터리**입니다. `--model-dir`는 `config.json`이 있는 모델 폴더 또는 모델 폴더들의 바로 위 디렉터리입니다. 둘 다 여러 번 지정할 수 있습니다. 기본 캐시는 `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, `HF_HOME/hub`, `~/.cache/huggingface/hub` 순서로 찾습니다. Docker 전용 볼륨, Ollama/GGUF, 원격 모델은 탐색하지 않습니다.

채팅 템플릿이 있는 CausalLM을 채팅 후보로, Sentence Transformers 메타데이터가 있는 모델을 임베딩 후보로 분류합니다. 용도가 불명확하거나 가중치/토크나이저/shard가 빠진 모델은 선택에서 제외합니다. 이는 파일 존재 검사이며 모든 가중치의 손상 검사는 아닙니다. 모델을 임의로 추측하거나 내려받지 않습니다. 후보여도 현재 런타임 지원 여부는 실제 기동/API 검증에서 확인합니다.

## 운영체제와 실행 환경

- Apple Silicon Mac: 기존 `~/.venv-vllm-metal/bin/vllm`을 사용합니다. **vLLM-Metal/MLX**이며 NVIDIA CUDA 서버가 아닙니다. 필요하면 `--executable /설치경로/bin/vllm`을 지정합니다. 현재 프로젝트의 `serve-metal.py`와 같은 CLI/Metal 환경 설정을 사용하되 선택 모델과 포트는 자식 환경에만 적용합니다.
- Linux / NVIDIA WSL2: 해당 환경에 이미 설치된 `vllm` CLI를 사용합니다. `python3 start.py --backend cuda`. WSL2 안에서는 `--os windows --backend cuda`도 지정할 수 있습니다. 이는 서버 실행 환경 선택입니다. Windows 호스트용 PowerShell 예제를 원하면 별도로 `--examples-shell powershell`을 지정합니다. 네이티브 Windows 서버 실행은 지원하지 않습니다. WSL 안에 있는 모델 캐시와 CUDA vLLM 설치가 필요합니다.
- 기존 Docker Compose의 자동 다운로드·재시작 정책을 피하기 위해 이 실행기는 Compose를 시작하지 않습니다. Docker에만 설치된 환경은 직접 실행 가능한 vllm 환경이 추가로 필요합니다. 설치 지침은 `docker/vllm/README.md`에서 확인하며, 실행기가 설치하거나 GPU 설정을 바꾸지는 않습니다.

CUDA에서는 MLX 양자화 모델을 제외합니다. 두 프로세스가 메모리를 함께 사용하며 CUDA 메모리 예산은 채팅 0.65 / 임베딩 0.20, Metal 기본 비율은 프로세스당 0.3입니다. 모든 모델 조합이 메모리에 들어간다고 보장하지 않습니다. 더 작은 로컬 모델을 선택하거나 기존 `.env`의 Metal 메모리 설정을 검토하세요.

## 비대화형 실행과 포트

```sh
python3 start.py --dry-run \
  --chat-model mlx-community/Qwen3-4B-4bit \
  --embedding-model mlx-community/Qwen3-Embedding-0.6B-8bit
```

위 모델이 목록에 있어야 합니다. 같은 모델에 여러 revision이 있으면 목록의 snapshot **절대 경로**를 모델 인자로 지정합니다. `--dry-run`을 제거하면 실제 시작합니다.

기본 포트는 `.env`의 `CHAT_PORT`, `EMBEDDING_PORT` 또는 8000/8001입니다. 충돌하면 기존 서비스를 건드리지 않고 종료합니다. `--chat-port 8100 --embedding-port 8101`로 바꿀 수 있습니다. 항상 `127.0.0.1`에 바인딩하며, 각 서버의 준비 대기 시간은 `--timeout 300`으로 조정합니다.

인증 키는 로그/예제에 출력하지 않습니다. 예제의 키 입력란에는 기존 `.env`와 같은 값을 넣습니다. 서버 원문 로그도 비밀 노출을 막기 위해 숨깁니다. 조기 종료 시 `--dry-run`의 실행 계획, 설치된 vllm 버전, 모델 지원, 메모리 여유를 확인하세요. offline 환경변수를 적용하고 로컬 snapshot을 전달하므로 누락된 파일을 자동 다운로드하지 않습니다.

## Mac 터미널과 Windows PowerShell의 통신 명령은 다릅니다

**서버 운영체제(`--os`)와 명령을 붙여 넣을 클라이언트 셸(`--examples-shell`)은 별개입니다.** 자동 모드는 실제 실행 환경 기준으로 Mac/Linux/WSL에서는 POSIX curl, Windows에서는 PowerShell을 선택합니다. WSL에서 `--os windows`를 지정해도 자동 예제는 WSL bash용입니다.

```sh
# Mac zsh/bash 또는 Linux/WSL bash용 예제
python3 start.py --examples-shell posix

# Windows PowerShell 5.1 / PowerShell 7에 붙여 넣을 예제
python3 start.py --examples-shell powershell
```

PowerShell에서는 `curl` 별칭에 의존하지 않고 `Invoke-RestMethod`를 사용합니다. JSON을 `ConvertFrom-Json` / `ConvertTo-Json -Depth 10`으로 구성하고 `[System.Text.Encoding]::UTF8.GetBytes(...)`로 보내 한글을 보존합니다. POSIX 셸에서는 JSON을 셸 인용 처리하여 `curl --data-binary`로 보냅니다. 두 방식 모두 모델 ID의 따옴표·특수문자를 안전하게 처리합니다. `\u...`는 JSON의 한글 표기이며 서버는 원래 한글로 해석합니다. 실제 선택 모델과 포트를 사용하고 키는 출력하지 않습니다.

**localhost는 명령을 실행하는 환경을 가리킵니다.** WSL 서버는 먼저 WSL 터미널에서 POSIX 예제로 확인하세요. Windows 호스트에서 WSL 서버로 `127.0.0.1` 접속이 되는지는 WSL 네트워크/localhost 전달 설정에 따라 달라집니다. 자동으로 된다고 보장하지 않습니다. 이미 접근 가능한 다른 주소나 터널이 있다면 다음 옵션으로 예제 주소만 바꿀 수 있습니다.

```sh
python3 start.py --examples-shell powershell \
  --examples-chat-url http://127.0.0.1:18100 \
  --examples-embedding-url http://127.0.0.1:18101
```

위 18100/18101은 **클라이언트에서 접근 가능한 전달 포트가 이미 있는 경우의 예시**입니다. 실제 주소로 바꾸세요. 이 옵션은 서버 포트·localhost 바인딩·WSL 설정·방화벽을 바꾸지 않습니다. 같은 환경에서 서버 포트를 바꾸려면 `--chat-port` / `--embedding-port`를 사용합니다. URL에 인증키·사용자명·비밀번호를 넣지 않습니다. HTTPS 프록시의 경로 접두어도 지정할 수 있습니다.

## 안전한 테스트와 검증 범위

```sh
python3 -m unittest discover -s . -p 'test_start.py' -v
```

테스트는 작은 임시 로컬 HTTP 서버와 임시 가중치 모형만 사용합니다. 실제 모델 다운로드/로드는 하지 않습니다. Mac에서 목록/실행 계획, 모의 API·프로세스 정리, 생성된 curl 명령의 bash 및 zsh 실제 실행을 검증했습니다. PowerShell은 생성 문자열·JSON 복원·UTF-8 본문 구성 및 주소 인용에 대한 회귀 테스트로 검증했으며 실제 Windows/PowerShell 실행은 미검증입니다. CUDA/WSL2는 명령 생성 경로만 검증했으며 실제 GPU 기동은 미검증입니다. 실제 모델 서버의 동시 기동은 사용자가 `python3 start.py`를 실행할 때 검증됩니다.
