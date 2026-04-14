# Static guest binary for minimal Firecracker rootfs (no shared libc path issues).
CXX      ?= g++
CXXFLAGS ?= -Wall -Wextra -O2 -std=c++17
LDFLAGS  ?= -static
TARGET   := agent

.PHONY: all clean

all: $(TARGET)

$(TARGET): agent.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)
