FROM scratch AS metadata-base
LABEL org.opencontainers.image.title="GitHub Actions fixture" \
      org.opencontainers.image.description="Container action validation=from Dockerfile" \
      org.opencontainers.image.base.name="scratch" \
      org.opencontainers.image.base.digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
      io.github.sayakmukhopadhyay.fixture="inherited non-OCI label"

FROM metadata-base
ARG VERSION
ARG COMMIT
COPY build-metadata/version-${VERSION}/commit-${COMMIT} /build-metadata
COPY fixture /fixture
