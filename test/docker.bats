#!/usr/bin/env bats
load test_helpers


function setup {
	start_web_container 1 >&2
	start_web_container 2 >&2
}

function teardown {
	docker ps -aq | tee docker-ps.out | xargs -r docker rm -fv >&2 || {
		set -x
		cat docker-ps.out
		cat /var/log/docker.log
		docker ps -a
		false
	} >&2
}


@test "[$TEST_FILE] -v /var/run/docker.sock:/tmp/docker.sock:ro" {
	# GIVEN nginx-proxy running on our docker host using the default unix socket 
	run nginxproxy -v /var/run/docker.sock:/tmp/docker.sock:ro
	assert_success
	nginxproxy_wait_for_log 3 "Watching docker events"

	# THEN querying the proxy without Host header → 503
	run nginxproxy_curl / --head
	assert_output -l 0 $'HTTP/1.1 503 Service Temporarily Unavailable\r'

	# THEN querying the proxy with Host header → 200
	assert_web_through_nginxproxy 1
	assert_web_through_nginxproxy 2
}


@test "[$TEST_FILE] -v /var/run/docker.sock:/f00.sock:ro -e DOCKER_HOST=unix:///f00.sock" {
	# GIVEN nginx-proxy running on our docker host using a custom unix socket 
	run nginxproxy -v /var/run/docker.sock:/f00.sock:ro -e DOCKER_HOST=unix:///f00.sock
	assert_success
	nginxproxy_wait_for_log 3 "Watching docker events"

	# THEN querying the proxy without Host header → 503
	run nginxproxy_curl / --head
	assert_output -l 0 $'HTTP/1.1 503 Service Temporarily Unavailable\r'

	# THEN querying the proxy with Host header → 200
	assert_web_through_nginxproxy 1
	assert_web_through_nginxproxy 2
}


@test "[$TEST_FILE] -e DOCKER_HOST=tcp://..." {
	# GIVEN a container exposing our docker host over TCP
	run docker_tcp bats-docker-tcp
	assert_success
	sleep 1s

	# GIVEN nginx-proxy running on our docker host using tcp to connect to our docker host
	run nginxproxy -e DOCKER_HOST="tcp://bats-docker-tcp:2375" --link bats-docker-tcp:bats-docker-tcp
	assert_success
	nginxproxy_wait_for_log 3 "Watching docker events"

	# THEN querying the proxy without Host header → 503
	run nginxproxy_curl / --head
	assert_output -l 0 $'HTTP/1.1 503 Service Temporarily Unavailable\r'

	# THEN querying the proxy with Host header → 200
	assert_web_through_nginxproxy 1
	assert_web_through_nginxproxy 2
}


@test "[$TEST_FILE] separated containers (nginx + docker-gen + nginx.tmpl)" {
	# GIVEN a simple nginx container
	docker_clean bats-nginx
	run docker run -d \
		--name bats-nginx \
		-v /etc/nginx/conf.d/ \
		-v /etc/nginx/certs/ \
		nginx:latest
	assert_success
	run retry 5 1s curl --silent --fail -A "before-docker-gen" --head http://$(docker_ip bats-nginx)/
	assert_output -l 0 $'HTTP/1.1 200 OK\r'

	# GIVEN docker-gen running on our docker host
	docker_clean bats-docker-gen
	run docker run -d \
		--name bats-docker-gen \
		-v /var/run/docker.sock:/tmp/docker.sock:ro \
		-v $BATS_TEST_DIRNAME/../nginx.tmpl:/etc/docker-gen/templates/nginx.tmpl:ro \
		--volumes-from bats-nginx \
		jwilder/docker-gen:latest \
			-notify-sighup bats-nginx \
			-watch \
			-only-exposed \
			/etc/docker-gen/templates/nginx.tmpl \
			/etc/nginx/conf.d/default.conf
	assert_success
	run docker_wait_for_log 6 bats-docker-gen "Watching docker events"
	assert_success

	# Give some time to the docker-gen container to notify bats-nginx so it 
	# reloads its config
	sleep 2s

	# THEN querying nginx without Host header → 503
	run curl --silent --head -A "after-docker-gen" http://$(docker_ip bats-nginx)/
	assert_output -l 0 $'HTTP/1.1 503 Service Temporarily Unavailable\r' || sh -c "
		set +x
		docker logs bats-nginx
		echo ----------------------
		docker logs bats-docker-gen
		echo ----------------------
		curl --silent http://$(docker_ip bats-nginx)/data
		echo ----------------------
		docker logs bats-web1
		echo ----------------------
		docker logs bats-web2
		false
	"

	# THEN querying nginx with Host header → 200
	run curl --silent http://$(docker_ip bats-nginx)/data --header "Host: web1.bats"
	assert_success
	assert_output web1
	
	run curl --silent http://$(docker_ip bats-nginx)/data --header "Host: web2.bats"
	assert_success
	assert_output web2
}


# start a container named 'bats-web$1' running a webserver listening
# on port 8000 and having the environment variable VIRTUAL_HOST set 
# to `web$1.bats`.
# When a HTTP request is made on path /data, it responds with the 
# content of the file in `fixtures/webservers/$1/data`
function start_web_container {
	local -ir ID=$1
	local -r CONTAINER=bats-web${ID}
	local -r HOST=web${ID}.bats

	docker_clean $CONTAINER
	run docker run -d \
		--name $CONTAINER \
		-e VIRTUAL_HOST=$HOST \
		--expose 8000 \
		-w /var/www \
		python:3 sh -c "
			echo 'web${ID}' > data
			python -m http.server
		"
	assert_success
	# Test that the container behaves
	run retry 20 .5s curl --silent --fail http://$(docker_ip $CONTAINER):8000/data
	assert_output web${ID}
}


function assert_web_through_nginxproxy {
	local -ir web_id=$1
	# WHEN
	run nginxproxy_curl /data --header "Host: web${web_id}.bats"

	# THEN
	assert_success
	assert_output web${web_id}
}
