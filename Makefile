.PHONY: mtproxy-deploy mtproxy-metric

mtproxy-deploy:
	./scripts/deploy-mtproxy.sh $(HOST)

mtproxy-metric:
	./scripts/mtproxy-metric.sh $(ARGS)
