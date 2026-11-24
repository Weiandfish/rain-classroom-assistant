.build/rainwatch: Sources/*.swift
	@mkdir -p .build
	swiftc -O -parse-as-library $^ -o $@
