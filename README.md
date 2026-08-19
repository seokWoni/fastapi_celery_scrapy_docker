# FastAPI + Celery + Scrapy

FastAPI로 크롤링 요청을 받고, RabbitMQ를 Celery broker로 사용하며, Celery Worker에서 Scrapy spider를 실행하는 비동기 크롤링 아키텍처입니다.

## 전체 흐름

```mermaid
sequenceDiagram
    participant Client
    participant FastAPI
    participant RabbitMQ
    participant CeleryWorker
    participant Scrapy

    Client->>FastAPI: POST /crawl {url, spider}
    FastAPI->>RabbitMQ: run_spider.delay(...)
    FastAPI-->>Client: {task_id}
    RabbitMQ->>CeleryWorker: task 수신
    CeleryWorker->>Scrapy: CrawlerProcess 실행
    Scrapy-->>CeleryWorker: 수집 결과
    Client->>FastAPI: GET /tasks/{task_id}
    FastAPI-->>Client: status + result
```

| 구성 요소 | 역할 |
|-----------|------|
| **FastAPI** | HTTP API, Celery task enqueue, task 상태 조회 |
| **RabbitMQ** | Celery broker (메시지 큐) |
| **Celery Worker** | task 실행, Scrapy spider 구동 |
| **Redis** (권장) | Celery result backend (task 결과/상태 저장) |

## 권장 디렉터리 구조

```
fastapi_celery_scrapy/
├── app/
│   ├── main.py              # FastAPI 앱
│   ├── api/
│   │   └── routes.py        # /crawl, /tasks/{id}
│   ├── celery_app.py        # Celery 인스턴스
│   └── tasks.py             # Celery task 정의
├── scraper/
│   ├── settings.py          # Scrapy settings
│   └── spiders/
│       └── example.py
├── rabbitmq/
│   └── enabled_plugins    # [rabbitmq_management].
├── docker-compose.yml
├── Dockerfile
├── requirements.txt
└── .env
```

## Scrapy + Celery 연동 (핵심)

Scrapy는 Twisted reactor를 사용하기 때문에 Celery worker 설정이 중요합니다.

| 방식 | 장점 | 단점 |
|------|------|------|
| **CrawlerProcess in task** (권장) | 코드로 제어, 결과 반환 쉬움 | worker당 reactor 1회 제한 |
| `subprocess: scrapy crawl` | 단순 | 결과 파싱/에러 처리 번거로움 |
| **Scrapyd** 별도 서비스 | 대규모/운영에 유리 | 구성 복잡 |

초기 구성에는 **CrawlerProcess in Celery task** 방식을 권장합니다.

Worker 실행 시 reactor 충돌을 피하려면 `--pool=solo`를 사용하세요.

```bash
celery -A app.celery_app worker --pool=solo -l info
```

## 핵심 코드 예시

### Celery 설정 (`app/celery_app.py`)

```python
from celery import Celery

celery_app = Celery(
    "scraper",
    broker="amqp://guest:guest@rabbitmq:5672//",
    backend="redis://redis:6379/0",
    include=["app.tasks"],
)
```

### Celery Task (`app/tasks.py`)

```python
from scrapy.crawler import CrawlerProcess
from scrapy.utils.project import get_project_settings
from app.celery_app import celery_app

@celery_app.task(bind=True)
def run_spider(self, spider_name: str, url: str):
    from scraper.spiders.example import ExampleSpider

    settings = get_project_settings()
    process = CrawlerProcess(settings)
    results = []

    class ResultSpider(ExampleSpider):
        def parse(self, response):
            item = {"url": response.url, "title": response.css("title::text").get()}
            results.append(item)
            return item

    process.crawl(ResultSpider, start_urls=[url])
    process.start()  # blocking — solo pool에서 1 task씩 실행

    return {"task_id": self.request.id, "items": results}
```

### FastAPI 라우트 (`app/api/routes.py`)

```python
from fastapi import APIRouter
from celery.result import AsyncResult
from app.tasks import run_spider
from app.celery_app import celery_app

router = APIRouter()

@router.post("/crawl")
def start_crawl(url: str, spider: str = "example"):
    task = run_spider.delay(spider, url)
    return {"task_id": task.id}

@router.get("/tasks/{task_id}")
def get_task_status(task_id: str):
    result = AsyncResult(task_id, app=celery_app)
    return {
        "task_id": task_id,
        "status": result.status,
        "result": result.result if result.ready() else None,
    }
```

### Scrapy Spider (`scraper/spiders/example.py`)

```python
import scrapy

class ExampleSpider(scrapy.Spider):
    name = "example"

    def __init__(self, start_urls=None, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.start_urls = start_urls or []
```

## RabbitMQ Management UI

웹 화면(`http://localhost:15672`)은 `rabbitmq_management` 플러그인이 켜져 있어야 합니다.

- 이미지 `rabbitmq:3-management`에 플러그인이 포함되어 있습니다.
- 추가로 `rabbitmq/enabled_plugins`를 마운트해서 명시적으로 on 합니다.

```erlang
[rabbitmq_management].
```

`hostname`과 `RABBITMQ_ERLANG_COOKIE`는 데이터 볼륨을 쓸 때 노드 인증이 깨지지 않도록 고정합니다.

기동 후 브라우저에서 **http://localhost:15672** 로 접속합니다. 기본 계정은 `guest` / `guest` 입니다.

## Docker Compose

```yaml
services:
  rabbitmq:
    image: rabbitmq:3-management
    hostname: rabbitmq
    ports:
      - "5672:5672"
      - "15672:15672"
    environment:
      RABBITMQ_ERLANG_COOKIE: ${RABBITMQ_ERLANG_COOKIE:-secretcookie}
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_DEFAULT_USER:-guest}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_DEFAULT_PASS:-guest}
    volumes:
      - ./rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro
      - rabbitmq_data:/var/lib/rabbitmq

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

  api:
    build: .
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000
    ports: ["8000:8000"]
    depends_on: [rabbitmq, redis]
    environment:
      CELERY_BROKER_URL: amqp://guest:guest@rabbitmq:5672//
      CELERY_RESULT_BACKEND: redis://redis:6379/0

  worker:
    build: .
    command: celery -A app.celery_app worker --pool=solo -l info
    depends_on: [rabbitmq, redis]
    environment:
      CELERY_BROKER_URL: amqp://guest:guest@rabbitmq:5672//
      CELERY_RESULT_BACKEND: redis://redis:6379/0

volumes:
  rabbitmq_data:
```

## requirements.txt

```
fastapi
uvicorn[standard]
celery[redis]
scrapy
pydantic-settings
```

## 운영 시 고려사항

1. **Worker concurrency**: Scrapy task는 `--pool=solo` 또는 `--concurrency=1`로 실행하는 것이 안전합니다.
2. **결과 저장**: 수집량이 크면 Celery result backend 대신 DB(S3, PostgreSQL 등)에 저장하고, task에는 ID만 반환하세요.
3. **재시도/타임아웃**: `@celery_app.task(bind=True, max_retries=3, soft_time_limit=300)` 등으로 설정하세요.
4. **모니터링**: Celery task 모니터링을 위해 [Flower](https://flower.readthedocs.io/) 추가를 고려하세요.
5. **Scrapy settings**: `ROBOTSTXT_OBEY`, `DOWNLOAD_DELAY`, `USER_AGENT` 등은 `scraper/settings.py`에서 관리하세요.

## 로컬 실행 (개요)

```bash
# 의존성 설치
pip install -r requirements.txt

# RabbitMQ, Redis 기동 (Docker)
docker compose up -d rabbitmq redis

# FastAPI
uvicorn app.main:app --reload

# Celery Worker (별도 터미널)
celery -A app.celery_app worker --pool=solo -l info
```

## API 사용 예시

```bash
# 크롤링 요청
curl -X POST "http://localhost:8000/crawl?url=https://example.com&spider=example"

# task 상태 조회
curl "http://localhost:8000/tasks/{task_id}"
```
