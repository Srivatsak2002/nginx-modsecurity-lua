FROM owasp/modsecurity-crs:4.11.0-nginx-202502070602

USER root

# Install required dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    libpcre3-dev \
    libssl-dev \
    zlib1g-dev \
    wget \
    unzip \
    curl \
    cmake \
    automake \
    libtool \
    make \
    gcc \
    pkg-config \
    libpcre2-dev \
    libxml2 \
    libxml2-dev \
    libyajl-dev \
    yajl-tools \
    doxygen \
    luarocks \
    libluajit-5.1-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone and build OpenResty's LuaJIT (for Lua support in Nginx)
RUN git clone https://github.com/openresty/luajit2.git /tmp/luajit2 && \
    cd /tmp/luajit2 && \
    make -j$(nproc) && make install && \
    ln -sf /usr/local/bin/luajit /usr/bin/luajit && \
    cd / && rm -rf /tmp/luajit2

# Set LuaJIT environment variables for luarocks
ENV LUAJIT_LIB=/usr/local/lib
ENV LUAJIT_INC=/usr/local/include/luajit-2.1
ENV LUA_INCDIR=/usr/local/include/luajit-2.1
ENV LUA_LIBDIR=/usr/local/lib

# Clone and build ModSecurity library
RUN git clone --depth 1 -b v3/master https://github.com/SpiderLabs/ModSecurity.git /tmp/ModSecurity && \
    cd /tmp/ModSecurity && \
    git submodule update --init && \
    ./build.sh && \
    ./configure && \
    make -j$(nproc) && make install && \
    mkdir -p /usr/local/modsecurity/lib/ && \
    cp -v /usr/local/modsecurity/lib/libmodsecurity.so.3 /usr/local/lib/ && \
    cp -v /usr/local/modsecurity/lib/libmodsecurity.so.3 /usr/lib/ && \
    ldconfig && \
    cd / && rm -rf /tmp/ModSecurity

# Clone the ModSecurity-nginx connector
RUN git clone https://github.com/SpiderLabs/ModSecurity-nginx.git /tmp/ModSecurity-nginx

# Download and build Nginx from source with Lua support
RUN wget http://nginx.org/download/nginx-1.27.3.tar.gz -P /tmp && \
    tar -xvzf /tmp/nginx-1.27.3.tar.gz -C /tmp

# Clone lua-nginx-module and lua-resty modules
RUN git clone https://github.com/openresty/lua-nginx-module.git /tmp/lua-nginx-module && \
    git clone https://github.com/openresty/lua-resty-core.git /tmp/lua-resty-core && \
    git clone https://github.com/openresty/lua-resty-lrucache.git /tmp/lua-resty-lrucache && \
    git clone https://github.com/openresty/lua-cjson.git /tmp/lua-cjson

RUN luarocks install uuid LUA_INCDIR=/usr/local/include/luajit-2.1 LUA_LIBDIR=/usr/local/lib

WORKDIR /tmp/nginx-1.27.3

# Build Nginx with Lua and ModSecurity support
RUN ./configure --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --with-http_ssl_module \
    --with-pcre \
    --add-module=/tmp/lua-nginx-module \
    --add-module=/tmp/ModSecurity-nginx \
    --with-cc-opt="-I${LUAJIT_INC} -I/usr/local/modsecurity/include" \
    --with-ld-opt="-L${LUAJIT_LIB} -L/usr/local/modsecurity/lib" \
    && make -j$(nproc) && make install

# Build and install lua-cjson
RUN cd /tmp/lua-cjson && \
    make LUA_INCLUDE_DIR=/usr/local/include/luajit-2.1 && \
    make install LUA_INCLUDE_DIR=/usr/local/include/luajit-2.1

# Install Lua modules manually
RUN mkdir -p /usr/local/share/lua/5.1/resty && \
    mkdir -p /usr/local/share/lua/5.1/ngx && \
    cp -r /tmp/lua-resty-core/lib/resty/* /usr/local/share/lua/5.1/resty/ && \
    cp -r /tmp/lua-resty-lrucache/lib/resty/* /usr/local/share/lua/5.1/resty/

# Create directory for custom Lua scripts
RUN mkdir -p /etc/nginx/lua

# Cleanup unnecessary files
RUN rm -rf /tmp/nginx-1.27.3 /tmp/nginx-1.27.3.tar.gz /tmp/lua-nginx-module /tmp/ModSecurity-nginx /tmp/lua-resty-core /tmp/lua-resty-lrucache /tmp/lua-cjson

# Configure Nginx to load Lua and ModSecurity modules and initialize lua-resty-core
RUN echo "load_module modules/ngx_http_lua_module.so;" > /etc/nginx/nginx.conf && \
    echo "load_module modules/ngx_http_modsecurity_module.so;" >> /etc/nginx/nginx.conf && \
    echo "events { worker_connections 1024; }" >> /etc/nginx/nginx.conf && \
    echo "http {" >> /etc/nginx/nginx.conf && \
    echo "    lua_package_path '/usr/local/share/lua/5.1/?.lua;/etc/nginx/lua/?.lua;;';" >> /etc/nginx/nginx.conf && \
    echo "    lua_package_cpath '/usr/local/lib/lua/5.1/?.so;/usr/local/lib/?.so;;';" >> /etc/nginx/nginx.conf && \
    echo "    init_by_lua_block { pcall(require, 'resty.core') }" >> /etc/nginx/nginx.conf && \
    echo "    server { listen 8080; location / { root /usr/share/nginx/html; } }" >> /etc/nginx/nginx.conf && \
    echo "}" >> /etc/nginx/nginx.conf

# Ensure ModSecurity library is found at runtime
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/modsecurity.conf && \
    echo "/usr/local/modsecurity/lib" >> /etc/ld.so.conf.d/modsecurity.conf && \
    ldconfig

# Set runtime library path
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/local/modsecurity/lib:$LD_LIBRARY_PATH

USER nginx

# Expose Nginx port
EXPOSE 8080

# Start Nginx in the foreground
CMD ["nginx", "-g", "daemon off;"]
