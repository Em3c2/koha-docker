all: reload build mysql run

reload: halt up provision

halt:
	vagrant halt

up:
	vagrant up

provision:
	vagrant provision

upgrade:
	vagrant ssh -c 'sudo docker pull mysql && sudo docker pull debian:wheezy && sudo docker pull busybox'

mysql: create_data_volume mysql_start

# Data volume container for mysql - for persistent data. Create new if not existing
create_data_volume:
	@echo "======= CREATING MYSQL DATA VOLUME CONTAINER ======\n"
	@vagrant ssh -c '(sudo docker inspect mysql_data > /dev/null && echo "mysql data volume already present") || \
	docker run -d --name mysql_data -v /var/lib/mysql busybox echo "create data volume"'

mysql_start:
	@ CURRENT_MYSQL_IMAGE=`vagrant ssh -c 'sudo docker inspect --format {{.Image}} koha_docker_mysql'` ;\
	LAST_MYSQL_IMAGE=`vagrant ssh -c 'sudo docker history --quiet --no-trunc mysql:5.6 | head -n 1'` ;\
	echo "Current image: $$CURRENT_MYSQL_IMAGE" ;\
	echo "Last image $$LAST_MYSQL_IMAGE" ;\
	if [ $$CURRENT_MYSQL_IMAGE = $$LAST_MYSQL_IMAGE ]; then \
		echo "mysql image up to date ... restarting"; \
		vagrant ssh -c 'sudo docker restart koha_docker_mysql '; \
	else \
		echo "restarting container from new image ..."; \
		vagrant ssh -c 'sudo docker stop koha_docker_mysql && sudo docker rm koha_docker_mysql'; \
		vagrant ssh -c 'sudo docker run -d --name koha_docker_mysql -p 3306:3306 --volumes-from mysql_data \
	  -e MYSQL_ROOT_PASSWORD=secret \
	  -e MYSQL_USER=admin \
	  -e MYSQL_PASSWORD=secret \
	  -e MYSQL_DATABASE=koha_name \
	  -t mysql:5.6 \
	  mysqld --datadir=/var/lib/mysql --user=mysql --max_allowed_packet=64M --wait_timeout=6000 --bind-address=0.0.0.0' ;\
	fi \

mysql_stop:
	@echo "======= RESTARTING MYSQL CONTAINER ======\n"
	vagrant ssh -c '(sudo docker stop koha_docker_mysql && sudo docker rm koha_docker_mysql) || true'

build:
	@echo "======= BUILDING KOHA CONTAINER ======\n"
	vagrant ssh -c 'sudo docker build -t digibib/koha /vagrant ' | tee build.log

# start koha with link to mysql container
run: mysql
	@echo "======= RUNNING KOHA CONTAINER ======\n"
	@vagrant ssh -c 'sudo docker run --link koha_docker_mysql:db -d --name koha_docker \
	-p 80:80 -p 8080:8080 -p 8081:8081 digibib/koha' || echo "koha docker container already running, please 'make delete' first"

stop: 
	@echo "======= STOPPING KOHA CONTAINER ======\n"
	vagrant ssh -c 'sudo docker stop koha_docker' || true

delete: stop
	vagrant ssh -c 'sudo docker rm koha_docker'

nsenter:
	vagrant ssh -c 'sudo nsenter --target `sudo docker inspect --format="{{.State.Pid}}" koha_docker` --mount --uts --ipc --net --pid '

browser:
	vagrant ssh -c 'firefox "http://localhost:8081/" > firefox.log 2> firefox.err < /dev/null' &

clean:
	vagrant destroy --force

tag = "$(shell git rev-parse HEAD)"
push:
	@echo "======= PUSHING KOHA CONTAINER ======\n"
	vagrant ssh -c 'sudo docker tag digibib/koha digibib/koha:$(tag)' | tee build.log
	vagrant ssh -c 'sudo docker push digibib/koha' | tee build.log

