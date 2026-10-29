SWIFT := /mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift

.PHONY: test
test:
	$(SWIFT) test
