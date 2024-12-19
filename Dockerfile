ARG GOLANG_VERSION=1.22.8
ARG CUDA_VERSION_11=11.3.1
ARG CUDA_VERSION_12=12.4.0
ARG ROCM_VERSION=6.1.2

#FROM nvidia/cuda:${CUDA_VERSION_12}-devel-ubuntu22.04 AS unified-builder-amd64
FROM --platform=linux/amd64 rocm/dev-centos-7:${ROCM_VERSION}-complete AS unified-builder-amd64
ARG GOLANG_VERSION
ARG CUDA_VERSION_11
ARG CUDA_VERSION_12
COPY ./scripts/rh_linux_deps.sh /
ENV PATH /opt/rh/devtoolset-10/root/usr/bin:/usr/local/cuda/bin:$PATH
ENV LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:/usr/local/cuda/lib64
RUN GOLANG_VERSION=${GOLANG_VERSION} sh /rh_linux_deps.sh
RUN yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-rhel7.repo && \
    dnf clean all && \
    dnf install -y \
    zsh \
    cuda-toolkit-$(echo ${CUDA_VERSION_11} | cut -f1-2 -d. | sed -e "s/\./-/g") \
    cuda-toolkit-$(echo ${CUDA_VERSION_12} | cut -f1-2 -d. | sed -e "s/\./-/g")
# TODO intel oneapi goes here...
ENV GOARCH amd64
ENV CGO_ENABLED 1
WORKDIR /go/src/github.com/ollama/ollama/
ENTRYPOINT [ "zsh" ]

FROM --platform=linux/amd64 unified-builder-amd64 AS build-amd64
COPY . .
ARG OLLAMA_SKIP_CUDA_GENERATE
ARG OLLAMA_SKIP_ROCM_GENERATE
ARG OLLAMA_FAST_BUILD
ARG VERSION
RUN --mount=type=cache,target=/root/.ccache \
    if grep "^flags" /proc/cpuinfo|grep avx>/dev/null; then \
        make -j $(nproc) dist ; \
    else \
        make -j 5 dist ; \
    fi
RUN cd dist/linux-$GOARCH && \
    tar -cf - . | pigz --best > ../ollama-linux-$GOARCH.tgz

FROM --platform=linux/amd64 scratch AS dist-amd64
COPY --from=build-amd64 /go/src/github.com/ollama/ollama/dist/ollama-linux-*.tgz /
FROM dist-$TARGETARCH AS dist


# For amd64 container images, filter out cuda/rocm to minimize size
FROM build-amd64 AS runners-cuda-amd64
RUN rm -rf \
    ./dist/linux-amd64/lib/ollama/libggml_hipblas.so \
    ./dist/linux-amd64/lib/ollama/runners/rocm*

FROM --platform=linux/amd64 ubuntu:22.04 AS runtime-amd64
RUN apt-get update && \
    apt-get install -y ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=build-amd64 /go/src/github.com/ollama/ollama/dist/linux-amd64/bin/ /bin/
COPY --from=runners-cuda-amd64 /go/src/github.com/ollama/ollama/dist/linux-amd64/lib/ /lib/

EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]

FROM runtime-$TARGETARCH
EXPOSE 11434
ENV OLLAMA_HOST 0.0.0.0
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]
