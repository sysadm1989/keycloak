# Универсальный образ Keycloak: PostgreSQL, Infinispan, темы и провайдеры из этого каталога.
# Сборка только amd64:
# docker build --platform linux/amd64 -t keycloak:26.8.0 --build-arg KEYCLOAK_VERSION=26.8.0 .
ARG KEYCLOAK_VERSION=26.8.0

FROM --platform=linux/amd64 quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_EVENT_METRICS_USER_ENABLED=true \
    KC_HTTP_ENABLED=true \
    KC_CACHE=ispn \
    KC_FEATURES=opentelemetry

COPY --chown=keycloak:keycloak providers/ /opt/keycloak/providers/
COPY --chown=keycloak:keycloak themes/ /opt/keycloak/themes/

RUN /opt/keycloak/bin/kc.sh build

FROM --platform=linux/amd64 quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

ARG KEYCLOAK_VERSION=26.8.0
LABEL org.opencontainers.image.title="keycloak" \
      org.opencontainers.image.version="${KEYCLOAK_VERSION}" \
      org.opencontainers.image.source="images/keycloak"

COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
