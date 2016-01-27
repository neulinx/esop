# Change this to suit your needs.
NAME=workshop
USERNAME=garyhai

RUNNING:=$(shell docker ps | grep $(NAME) | cut -f 1 -d ' ')
ALL:=$(shell docker ps -a | grep $(NAME) | cut -f 1 -d ' ')

all: build

build:
	docker build -t $(USERNAME)/$(NAME) .

run: clean
	docker run -itd --name $(NAME) $(USERNAME)/$(NAME)

# Removes existing containers.
clean:
ifneq ($(strip $(RUNNING)),)
	docker stop $(RUNNING)
endif
ifneq ($(strip $(ALL)),)
	docker rm $(ALL)
endif
