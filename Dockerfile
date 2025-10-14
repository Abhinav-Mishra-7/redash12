FROM node:18-bookworm AS frontend-builder

RUN npm install --global --force yarn@1.22.22

ARG skip_frontend_build
ENV CYPRESS_INSTALL_BINARY=0
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1

RUN useradd -m -d /frontend redash
USER redash

WORKDIR /frontend
COPY --chown=redash package.json yarn.lock .yarnrc /frontend/
COPY --chown=redash viz-lib /frontend/viz-lib
COPY --chown=redash scripts /frontend/scripts

ARG code_coverage
ENV BABEL_ENV=${code_coverage:+test}

RUN yarn config set network-timeout 300000
RUN if [ "x$skip_frontend_build" = "x" ]; then yarn --frozen-lockfile --network-concurrency 1; fi

COPY --chown=redash client /frontend/client
COPY --chown=redash webpack.config.js /frontend/
RUN if [ "x$skip_frontend_build" = "x" ]; then yarn build; else mkdir -p /frontend/client/dist; touch /frontend/client/dist/multi_org.html; touch /frontend/client/dist/index.html; fi


# -------------------------------
# Redash Backend Build
# -------------------------------
FROM python:3.10-slim-bookworm

EXPOSE 5000

RUN useradd --create-home redash

# ✅ Install system dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  pkg-config \
  curl \
  gnupg \
  build-essential \
  pwgen \
  libffi-dev \
  sudo \
  git-core \
  libkrb5-dev \
  libpq-dev \
  g++ unixodbc-dev \
  xmlsec1 \
  libssl-dev \
  default-libmysqlclient-dev \
  freetds-dev \
  libsasl2-dev \
  unzip \
  libsasl2-modules-gssapi-mit \
  ca-certificates \
  && apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV POETRY_VERSION=2.1.4
ENV POETRY_HOME=/etc/poetry
ENV POETRY_VIRTUALENVS_CREATE=false
RUN curl -sSL https://install.python-poetry.org | python3 -

RUN /etc/poetry/bin/poetry cache clear pypi --all

COPY pyproject.toml poetry.lock ./
ARG POETRY_OPTIONS="--no-root --no-interaction --no-ansi"
ARG install_groups="main,all_ds,dev"
RUN /etc/poetry/bin/poetry install --only $install_groups $POETRY_OPTIONS

COPY --chown=redash . /app
COPY --from=frontend-builder --chown=redash /frontend/client/dist /app/client/dist
RUN chown -R redash:redash /app

# ✅ MongoDB + DNSPython fix (permanent install)
USER root
RUN pip install --upgrade pymongo dnspython && \
    update-ca-certificates

# ✅ Add MongoDB Query Runner (if not already bundled)
RUN wget -O /app/redash/query_runner/mongodb.py https://raw.githubusercontent.com/EverythingMe/redash-query-runner-mongodb/master/mongodb.py && \
    grep -qxF "from .mongodb import MongoDB" /app/redash/query_runner/__init__.py || echo "from .mongodb import MongoDB" >> /app/redash/query_runner/__init__.py

# ✅ Make entrypoint executable
COPY bin/docker-entrypoint /app/bin/docker-entrypoint
RUN chmod +x /app/bin/docker-entrypoint

USER redash

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
