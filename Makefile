# permisos-agente-ia-eks — `make` sin argumentos muestra este menú.
# El modo (aws o local) y el destino de KubeBolt (cloud u oss) salen de lab.env
# (copia lab.env.example); sin lab.env, local con KubeBolt Cloud.

SHELL := /bin/bash
MODE := $(shell [ -f lab.env ] && . ./lab.env; echo $${LAB_MODE:-local})
S := ./scripts

.DEFAULT_GOAL := help
.PHONY: help up down kubebolt kubebolt-quitar romper reparar estado ej2 ej3 ej4 ej5 ej6 limpiar tienda ui env

help: ## este menú
	@echo "Laboratorio «¿Qué permisos le das a un agente de IA en EKS y AWS?» · modo $(MODE)"
	@echo
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  make %-16s %s\n", $$1, $$2}'
	@echo
	@echo "Guía: README.md · docs/$(MODE).md · docs/ejercicios.md · docs/kubebolt.md"

up: ## crea el laboratorio (kind en local, ~5 min; EKS en AWS, ~30 min)
	@$(S)/$(MODE)-up.sh

down: ## lo borra todo (en AWS, deja de cobrar)
	@$(S)/$(MODE)-down.sh

kubebolt: ## conecta el clúster a KubeBolt (Cloud u open source, según KUBEBOLT en lab.env)
	@$(S)/kubebolt.sh

kubebolt-quitar: ## desinstala el agente (y KubeBolt open source, si está)
	@$(S)/kubebolt.sh quitar

romper: ## el incidente: rota la contraseña de orders-api
	@$(S)/incidente.sh romper

reparar: ## sincroniza el Secret y reinicia orders-api
	@$(S)/incidente.sh reparar

estado: ## la tienda, orders-api y la sincronización del Secret
	@$(S)/incidente.sh estado

ej2: ## ejercicio 2: lo que KubeBolt puede y no puede, probado fuera del modelo
	@$(S)/ejercicios.sh ej2

ej3: ## ejercicio 3: planta una línea con pinta de runbook en los logs
	@$(S)/ejercicios.sh ej3

ej4: ## ejercicio 4: planta la misma orden, escrita para una IA
	@$(S)/ejercicios.sh ej4

ej5: ## ejercicio 5: rota otra vez y planta las dos líneas para Autopilot
	@$(S)/ejercicios.sh ej5

ej6: ## ejercicio 6: el rastro (CloudTrail o auditoría de kind; MIN=45)
	@MIN=$(MIN) $(S)/ejercicios.sh ej6

limpiar: ## reinicia orders-api: se van las líneas plantadas
	@$(S)/ejercicios.sh limpiar

tienda: ## abre la tienda en http://localhost:8080 (Ctrl+C para cerrar)
	@echo "http://localhost:8080 (Ctrl+C para cerrar)"
	@kubectl --kubeconfig .lab/kubeconfig -n shop-frontend port-forward svc/shop-web 8080:80

ui: ## KubeBolt open source en http://localhost:3000 (usuario admin)
	@printf "usuario admin · contraseña: "; kubectl --kubeconfig .lab/kubeconfig -n kubebolt get secret kubebolt-admin-password -o jsonpath='{.data.password}' | base64 -d; echo
	@echo "http://localhost:3000 (Ctrl+C para cerrar)"
	@kubectl --kubeconfig .lab/kubeconfig -n kubebolt port-forward svc/kubebolt 3000:80

env: ## imprime el export para usar kubectl con el clúster del laboratorio
	@echo "export KUBECONFIG=$(CURDIR)/.lab/kubeconfig"
