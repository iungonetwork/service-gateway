TODO more details

### Prerequisites

docker version 18.09+
docker-compose version 1.23+


1. bootstraping: clone and run ./bootstrap.sh
2. run tests: docker-compose run --rm -e ADD_AP=y -e ADD_USER=y -e KILL_AP=y test tests
3. teardown: docker-compose down && sudo rm -rf .data && rm docker-compose.yml
