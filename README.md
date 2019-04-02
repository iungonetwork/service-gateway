TODO more details

## Getting Started

These instructions will get you a copy of the beta project version up and running on your local machine for development and testing purposes. 

### Prerequisites
```
docker version 18.09+
docker-compose version 1.23+
```

### Installing

```
1. Clone repo and `cd service-gateway`
2. Make file executable `chmod +x bootstrap.sh`
3. Run ./bootstrap.sh
```

### Testing

Run tests
```
docker-compose run --rm -e ADD_AP=y -e ADD_USER=y -e KILL_AP=y test tests
```

### Teardown

```
docker-compose down && sudo rm -rf .data && rm docker-compose.yml
```
