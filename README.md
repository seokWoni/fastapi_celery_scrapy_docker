# Docker container

## RabbitMQ Management UI

웹 화면(`http://localhost:15672`)은 `rabbitmq_management` 플러그인이 켜져 있어야 합니다.

- 이미지 `rabbitmq:3-management`에 플러그인이 포함되어 있습니다.
- 추가로 `rabbitmq/enabled_plugins`를 마운트해서 명시적으로 on 합니다.

```erlang
[rabbitmq_management].
```

`hostname`과 `RABBITMQ_ERLANG_COOKIE`는 데이터 볼륨을 쓸 때 노드 인증이 깨지지 않도록 고정합니다.

기동 후 브라우저에서 **http://localhost:15672** 로 접속합니다. 기본 계정은 `guest` / `guest` 입니다.

## python

`python/Dockerfile`이 `python/requirements.txt`로 의존성을 설치한 이미지를 만듭니다. Compose의 `api`와 `worker`는 이 이미지(`fastapi-celery-scrapy:py310`)를 공유하고, 애플리케이션 코드는 `src/`를 `/app`에 마운트합니다.

```bash
# python/requirements.txt 기준으로 이미지 빌드
docker compose build api

# 빌드한 이미지로 컨테이너 기동
docker compose up -d
```

이미지 이름과 빌드 컨텍스트는 `docker-compose.yml`에서 이렇게 지정합니다.

```yaml
build:
  context: ./python
  dockerfile: Dockerfile
image: fastapi-celery-scrapy:py310
```

## requirements.txt

패키지 버전은 `python/requirements.txt`에 `패키지==버전`으로 고정되어 있습니다. 이미지 빌드 시 `pip install -r requirements.txt`로 설치됩니다.

