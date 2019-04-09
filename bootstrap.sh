#!/bin/bash

mkdir .data

cat << EOF > docker-compose.yml
version: "3.5"

services:

  controller:
    image: docker.iungo.network/net-controller
    cap_add:
      - NET_ADMIN   
    volumes:
      - ./.data/openvpn/ccd:/ccd
    environment:
      REDIS_HOST: redis
      DB_HOST: mysql
      DB_USER: root
      DB_PASS: root
      SIGNET: 10.8.0.0/16
      SIGNET_IP_POOL_EXCEPTION: ^10\.8\.0\.1
      SIGNET_GW: 172.28.1.15
      AMQP_URI: amqp://user:pass@rabbitmq:5672
      AMQP_BILLING_QUEUE: billing-service
      SECURITY_COLLECTOR: 172.28.1.17:3000
      DEBUG: 'iungo:*'
    ports:
      - 8000:80
    depends_on:
      - redis
      - rabbitmq
      - mysql
    networks:
      default:
        ipv4_address: 172.28.1.10

  redis:
    image: redis:4-alpine
    command: redis-server --appendonly yes
    volumes:
      - ./.data/redis:/data
    networks:
      default:
        ipv4_address: 172.28.1.11

  rabbitmq:
    image: rabbitmq:management-alpine
    ports:
      - 15672:15672
    volumes:
      - ./.data/rabbitmq:/var/lib/rabbitmq
    environment:
      - RABBITMQ_DEFAULT_USER=user
      - RABBITMQ_DEFAULT_PASS=pass
    networks:
      default:
        ipv4_address: 172.28.1.12

  mysql:
    image: mysql:5.5
    environment:
      MYSQL_ROOT_PASSWORD: root
    volumes:
      - ./.data/mysql:/var/lib/mysql
    networks:
      default:
        ipv4_address: 172.28.1.13

  pkim:
    image: docker.iungo.network/net-pkim
    volumes:
      - ./.data/pki:/pki
    networks:
      default:
        ipv4_address: 172.28.1.14

  openvpn:
    image: docker.iungo.network/net-openvpn
    cap_add:
      - NET_ADMIN
    volumes:
      - ./.data/openvpn/ccd:/etc/openvpn/ccd
      - ./.data/pki:/pki
    ports:
      - 1194:1194
    environment:
      RADIUS_IP: 172.28.1.16
      CONTROLLER_IP: 172.28.1.10
    networks:
      default:
        ipv4_address: 172.28.1.15

  freeradius:
    image: docker.iungo.network/net-freeradius
    cap_add:
      - NET_ADMIN   
    environment:
      RLM_REST_CONNECT_URL: http://controller
      DB_HOST: mysql
      SIGNET: 10.8.0.0/16
      SIGNET_GW: 172.28.1.15
    volumes:
     - ./.data/pki:/pki
    networks:
      default:
        ipv4_address: 172.28.1.16

  security:
    image: docker.iungo.network/net-security
    cap_add:
      - NET_ADMIN
    environment:
      AMQP_URI: amqp://user:pass@rabbitmq:5672
      AMQP_QUEUE: security-threat
      DEBUG: 'iungo:sec:*,iungo:sec:collector:debug'
    networks:
      default:
        ipv4_address: 172.28.1.17

  test:
    image: docker.iungo.network/net-test
    cap_add:
      - NET_ADMIN   
    environment:
      RADIUS_IP: 172.28.1.16
      SIGNET_GW: 10.8.0.1
    volumes:
      - ./.data/test:/tmp

  geth:
    image: ethereum/client-go:alpine
    command: --testnet --syncmode fast --ws --wsaddr 0.0.0.0 --wsapi "eth,web3,net" --wsorigins "*" --verbosity=1
    ports:
      - 8545:8545
      - 8546:8546
    volumes:
      - .data/geth:/root/.ethereum
    networks:
      default:
        ipv4_address: 172.28.1.18  

  payments-token:
    image: docker.iungo.network/payments-token
    environment:
      WEB3_WS_PROVIDER_URI: http://geth:8546
      TOKEN: INGX
      TOKEN_DECIMALS: 4
      CONTRACT_ADDRESS: '0x05CE1108d503a6b1d66Ca79f54E9bC537222c36E'
      AMQP_URI: amqp://user:pass@rabbitmq:5672
      AMQP_QUEUE: billing
      REDIS_HOST: redis
    depends_on:
      - redis
      - geth
    networks:
      default:
        ipv4_address: 172.28.1.19

networks:
  default:
    name: service
    driver: bridge
    driver_opts:
      com.docker.network.enable_ipv6: "false"
    ipam:
      driver: default
      config:
       - subnet: 172.28.1.0/24
EOF

# Start databases/messaging
docker-compose up -d redis rabbitmq mysql
echo -n 'Waiting for MySQL to start'
until docker-compose exec mysql mysql -uroot -proot -e "SELECT 1" > /dev/null 2>&1; do
  echo -n '.'
  sleep 1
done
echo

# Initialize PKIM
docker-compose up -d pkim
docker-compose exec pkim pkim-init
docker-compose exec pkim pkim-genroot

# Initialize OpenVPN
docker-compose exec pkim pkim-issue server server any
docker-compose run --rm openvpn openssl gendh -out /pki/dh/openvpn -2 2048
docker-compose up -d openvpn

# Initialize freeradius
docker-compose exec mysql mysql -uroot -proot -e "CREATE DATABASE radius"
docker-compose run --rm freeradius openssl dhparam -out /pki/dh/freeradius 2048
docker-compose run --rm freeradius cat /etc/raddb/mods-config/sql/main/mysql/schema.sql | docker-compose exec -T mysql mysql -uroot -proot radius
docker-compose exec pkim pkim-issue radius server any
docker-compose up -d freeradius

# Initialize controller/security
docker-compose exec mysql mysql -uroot -proot -e "CREATE DATABASE security"
docker-compose run --rm controller cat /app/security.sql | docker-compose exec -T mysql mysql -uroot -proot security
docker-compose up -d controller security

# Setup payments
docker-compose up -d geth payments-token
mkdir -p .data/payments/token
echo "Generating wallet mnemonic"
docker-compose exec payments-token node src/util/generate_mnemonic.js | tr -d "\r\n" > .data/payments/token/wallet-mnemonic
echo "Generating wallet addresses"
docker-compose exec payments-token node src/util/generate_wallet.js "$(cat .data/payments/token/wallet-mnemonic)" 1000 > .data/payments/token/wallet-addresses
echo "Setting up wallet address pool"
cat .data/payments/token/wallet-addresses | tr -d '\r' | tr '\n' '\0' | docker-compose exec -T payments-token xargs -0 -L1 -I'%' curl -s -d"{\"address\": \"%\"}" -H "Content-Type: application/json" payments-token/pool/free > /dev/null