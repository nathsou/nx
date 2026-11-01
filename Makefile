# nx: a static recompilation engine for Switch games.
#   make gen GAME=<name>   recompile data/<name>/exefs to C (generated/<name>/)
#   make GAME=<name>       build the app (build/nx, shared by every game) and that game's code (build/<name>/game.*)
#   ./build/nx data/<name>
# macOS: Homebrew clang/SDL3/FFmpeg, Metal renderer.
# Windows: MSYS2 UCRT64 shell (see docs/BUILD-windows.md), clang + Vulkan renderer.
# Linux: clang + Vulkan renderer, x86-64 or aarch64 (see docs/linux.md).
# iOS / iPadOS: `make ios GAME=<name>` on a Mac (Xcode; tools/build_deps_ios.sh first), Metal renderer (see docs/ios.md).
UNAME := $(shell uname -s)
comma := ,
ifeq ($(PLATFORM),ios)
else ifneq ($(filter MINGW% MSYS% CYGWIN% Windows_NT,$(UNAME) $(OS)),)
PLATFORM := windows
else ifeq ($(UNAME),Linux)
PLATFORM := linux
else
PLATFORM := macos
endif

# iOS: IOS_SDK iphonesimulator (default) or iphoneos, IOS_MIN the oldest iOS to run on; Xcode's clang for that SDK.
# The platform layer is macOS's (runtime/platform/macos.c, with TARGET_OS_IPHONE parts).
ifeq ($(PLATFORM),ios)
IOS_SDK  ?= iphonesimulator
IOS_MIN  ?= 17.0
IOS_TARGET := arm64-apple-ios$(IOS_MIN)$(if $(filter iphonesimulator,$(IOS_SDK)),-simulator)
B        := build/$(IOS_SDK)
DEPS     ?= build/deps-$(IOS_SDK)
PLATFORM_SRC := macos
endif

# GAME: the game to generate / build (its files in GAME_DIR, default data/<GAME>: exefs/ and romfs/ from extract.mts)
GAME     ?= dread
GAME_DIR ?= data/$(GAME)

# Linux: ARCH (x86_64 / aarch64, default this machine's) picks the target, separately from PLATFORM. The generated code
# differs per arch (AArch64 hosts run the guest's FP/SIMD as inline asm, others use the portable C of simd.h), so a
# cross build has its own generated-<arch>/ and build/<arch>/; SYSROOT is the target's root filesystem (headers, libs).
GENROOT  ?= generated
ifeq ($(PLATFORM),linux)
HOSTARCH := $(patsubst arm64,aarch64,$(shell uname -m))
ARCH     ?= $(HOSTARCH)
ifneq ($(ARCH),$(HOSTARCH))
CROSS    := --target=$(ARCH)-linux-gnu $(if $(SYSROOT),--sysroot=$(SYSROOT))
GENROOT  := generated-$(ARCH)
B        ?= build/$(ARCH)
endif
GENSIMD  := --simd $(if $(filter aarch64,$(ARCH)),asm,c)
endif

GEN      := $(GENROOT)/$(GAME)

# B: build dir. MACOS_MIN: oldest macOS to run on (default: this one). DEPS: prefix with SDL3 / FFmpeg instead of
# Homebrew's (make deps). `make app` sets all three (build/mac15, 15.0, build/deps); plain `make` uses none.
B         ?= build
MACOS_MIN ?=
DEPS      ?=
MINFLAG  := $(if $(MACOS_MIN),-mmacosx-version-min=$(MACOS_MIN))
CC       := $(if $(IOS_SDK),xcrun -sdk $(IOS_SDK) clang -target $(IOS_TARGET),clang $(MINFLAG) $(CROSS))
CXX      := $(if $(IOS_SDK),xcrun -sdk $(IOS_SDK) clang++ -target $(IOS_TARGET),clang++ $(MINFLAG) $(CROSS))
IMGUI    := third_party/imgui
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -fvisibility=hidden -Iruntime

# The game code (made by `make gen` from your own game files) is its own library, build/<game>/game.<ext>
# (runtime/gamelib.h); the app holds none of it and loads the one built for the game files it is given.
# (strip: with no generated code the space between the two would be all that's left, and $(if) takes a lone space as
# true. No comment after the value: make keeps the spaces before it)
GEN_SRC  := $(strip $(wildcard $(GEN)/*/*.c) $(wildcard $(GEN)/gamelib_modules.c))
GB       := $(B)/$(GAME)
GEN_OBJ  := $(patsubst %.c,$(GB)/obj/%.o,$(patsubst $(GEN)/%,%,$(GEN_SRC))) $(GB)/obj/tools/gamelib_entry.o
# The engine, and every game profile (games/<id>/*.c: they register themselves, runtime/game.h)
RT_SRC   := $(wildcard runtime/*.c runtime/*.cpp) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/$(or $(PLATFORM_SRC),$(PLATFORM)).c \
            $(wildcard games/*/*.c)
RT_HDRS  := $(wildcard runtime/*.h games/*/*.h) $(wildcard runtime/platform/*.h) $(wildcard runtime/nvn/*.h) \
            $(wildcard runtime/nvn/maxwell/*.h) $(wildcard runtime/nvn/vulkan/*.h) $(wildcard runtime/ui/*.h)
UI_SRC   := $(wildcard runtime/ui/*.mm)
UI_OBJ   := $(patsubst runtime/%.mm,$(B)/rt/%.o,$(UI_SRC))
IMGUI_OBJ := $(B)/imgui/imgui.o $(B)/imgui/imgui_draw.o $(B)/imgui/imgui_tables.o $(B)/imgui/imgui_widgets.o \
             $(B)/imgui/imgui_impl_sdl3.o

ifeq ($(PLATFORM),ios)
APP      := $(B)/nx.app
EXE      := $(APP)/nx
DEPINC   := -I$(DEPS)/include
LDFLAGS  := -L$(DEPS)/lib -lSDL3 -lavformat -lavcodec -lavutil -lswscale -lzstd -lbz2 -lz -liconv \
            $(addprefix -framework ,CoreFoundation Foundation Metal QuartzCore UIKit ImageIO CoreGraphics \
              UniformTypeIdentifiers CoreMedia CoreVideo CoreAudio AudioToolbox AVFoundation CoreBluetooth CoreMotion \
              GameController CoreText OpenGLES $(if $(filter iphoneos,$(IOS_SDK)),MetalFX)) -weak_framework CoreHaptics -Wl,-rpath,@executable_path/Frameworks
BACKEND_SRC := $(wildcard runtime/nvn/*.m)
BACKEND_OBJ := $(patsubst runtime/%.m,$(B)/rt/%.o,$(BACKEND_SRC))
IMGUI_OBJ += $(B)/imgui/imgui_impl_metal.o
UIFLAGS  := -fobjc-arc
# the game code: a library in the app (Frameworks/), linked against the app's own runtime functions
GAMELIB  := $(GB)/game.dylib
GAMELIB_LDFLAGS := -dynamiclib -Wl,-undefined,dynamic_lookup -install_name @rpath/game.dylib
else ifeq ($(PLATFORM),macos)
SDL      := $(or $(DEPS),/opt/homebrew/opt/sdl3)
FFMPEG   := $(or $(DEPS),/opt/homebrew/opt/ffmpeg)
ZSTD     := $(or $(DEPS),/opt/homebrew/opt/zstd)
EXE      := $(B)/nx
DEPINC   := -I$(SDL)/include -I$(FFMPEG)/include -I$(ZSTD)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,$(FFMPEG)/lib \
            -L$(ZSTD)/lib -lzstd -Wl,-rpath,$(ZSTD)/lib \
            -framework CoreFoundation -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
BACKEND_SRC := $(wildcard runtime/nvn/*.m)
BACKEND_OBJ := $(patsubst runtime/%.m,$(B)/rt/%.o,$(BACKEND_SRC))
IMGUI_OBJ += $(B)/imgui/imgui_impl_metal.o
UIFLAGS  := -fobjc-arc
GAMELIB  := $(GB)/game.dylib
GAMELIB_LDFLAGS := -dynamiclib -undefined dynamic_lookup  # (the runtime functions it calls: the app's own)
else ifeq ($(PLATFORM),linux)
EXE      := $(B)/nx
DEPINC   := $(if $(DEPS),-I$(DEPS)/include)
ifeq ($(ARCH),x86_64)
GENARCH  ?= -march=x86-64-v3  # as on Windows: AVX2 + FMA for the lifted FP/SIMD code (checked at startup)
endif
GENFLAGS += $(GENARCH) -fPIC
OSFLAGS  := -Wno-format  # (%llx for uint64_t, which is unsigned long here: the same size)
# shaderc as the system's pkg-config file names it (Arch / Fedora / AOSC ship only libshaderc_shared, issue #22);
# without one -lshaderc (Debian / Ubuntu's libshaderc.so). SHADERC=... overrides it.
SHADERC  ?= $(shell pkg-config --libs shaderc 2>/dev/null || echo -lshaderc)
# -rdynamic: crash backtraces name host functions (runtime/platform/linux.c)
LDFLAGS  := -fuse-ld=lld -rdynamic $(if $(DEPS),-L$(DEPS)/lib) -lSDL3 -lavformat -lavcodec -lavutil -lswscale -lzstd \
            -lvulkan $(SHADERC) -lpthread -ldl -lm
BACKEND_SRC := $(wildcard runtime/nvn/vulkan/*.c) $(wildcard runtime/nvn/vulkan/*.cpp)
BACKEND_OBJ := $(patsubst runtime/%.cpp,$(B)/rt/%.o,$(patsubst runtime/%.c,$(B)/rt/%.o,$(BACKEND_SRC)))
IMGUI_OBJ += $(B)/imgui/imgui_impl_vulkan.o
UIFLAGS  := -x c++  # the .mm UI sources are plain C++ apart from __APPLE__ blocks
GAMELIB  := $(GB)/game.so
GAMELIB_LDFLAGS := -shared -fuse-ld=lld  # (the runtime functions it calls: the app's own, -rdynamic)
else
EXE      := $(B)/nx.exe
DEPINC   := $(if $(DEPS),-I$(DEPS)/include)
OSFLAGS  := -D_FILE_OFFSET_BITS=64 -D_POSIX_THREAD_SAFE_FUNCTIONS -D_CRT_RAND_S -DWIN32_LEAN_AND_MEAN -DNOMINMAX \
            $(if $(RELEASE),-DLARECOMP_ZIP_BUILD)  # (the log's [info] line: the release zip)
GENARCH  ?= -march=x86-64-v3  # AVX2 + FMA for the lifted FP/SIMD code (simd.h); override for older CPUs
GENFLAGS += -D_FILE_OFFSET_BITS=64 $(GENARCH)
LDFLAGS  := -fuse-ld=lld -Wl,--stack,16777216 $(if $(DEPS),-L$(DEPS)/lib) -lSDL3 -lavformat -lavcodec -lavutil -lswscale -lzstd \
            -lvulkan-1 -lws2_32 -lwinmm -lole32 -lshell32 -lcomdlg32 -luuid -lshaderc_shared \
            $(if $(RELEASE),-Wl$(comma)--subsystem$(comma)windows)  # release: no console window (log -> lasrecomp.log + lasrecomp-backup-*.log)
BACKEND_SRC := $(wildcard runtime/nvn/vulkan/*.c) $(wildcard runtime/nvn/vulkan/*.cpp)
BACKEND_OBJ := $(patsubst runtime/%.cpp,$(B)/rt/%.o,$(patsubst runtime/%.c,$(B)/rt/%.o,$(BACKEND_SRC)))
BACKEND_OBJ += $(B)/rt/platform/windows_rc.o  # the .exe's icon (Explorer, taskbar)
WINDRES  ?= windres
IMGUI_OBJ += $(B)/imgui/imgui_impl_vulkan.o
UIFLAGS  := -x c++ $(OSFLAGS)  # the .mm UI sources are plain C++ apart from __APPLE__ blocks
GAMELIB  := $(GB)/game.dll
# the runtime functions it calls: exported by the .exe, linked through its import library
LDFLAGS  += -Wl,--export-all-symbols -Wl,--out-implib,$(B)/nx.dll.a
GAMELIB_LDFLAGS := -shared -fuse-ld=lld $(B)/nx.dll.a
endif

# GAMELIB_ID: what the game code library is built from (the generator, the headers it is compiled against, the flags):
# the same for every game, so one app loads them all. A library with another id is never loaded. (A game's own
# patches change its generated code: `make gen` again after editing games/<id>/patches*.)
GAMELIB_SRCS := tools/games.py tools/gen_game.py tools/gen.py tools/lifter.py tools/analyze.py tools/nso.py tools/passes.py \
                tools/simd_c.py tools/gamelib_entry.c runtime/hle/hle_symbols.txt \
                runtime/cpu.h runtime/simd.h runtime/simd_fp.h runtime/gamelib.h
# (of runtime/rt.h, only the module layout's constants: tools/gen_game.py)
GAMELIB_ID := $(shell (cat $(GAMELIB_SRCS); grep -E '^.define (MAIN_BASE|HLE_BASE)' runtime/rt.h; echo '$(GENFLAGS)') | \
                (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-16)
# The library's own id adds the game's main build ID (what `make gen` generated from: $(GEN)/main_build_id.txt), so
# the app picks the library built for the game files it is given (runtime/gamelib.h gamelib_full_id)
GAMELIB_BUILD := $(shell cut -c1-16 $(GEN)/main_build_id.txt 2>/dev/null)
GAMELIB_FULL_ID := $(GAMELIB_ID)-$(or $(GAMELIB_BUILD),unknown)

RT_OBJ   := $(patsubst games/%.c,$(B)/rt/games/%.o,$(patsubst runtime/%.cpp,$(B)/rt/%.o,$(patsubst runtime/%.c,$(B)/rt/%.o,$(RT_SRC))))
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn -I. $(DEPINC) $(OSFLAGS)
CXXFLAGS := -O2 -g -std=c++17 -I$(IMGUI) -I$(IMGUI)/backends -Iruntime -Iruntime/nvn $(DEPINC)

all: $(EXE) $(if $(GEN_SRC),$(GAMELIB))

$(GB)/obj/%.o: $(GEN)/%.c runtime/cpu.h runtime/simd.h runtime/simd_fp.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

# (the id in a file that changes only when the id does: make doesn't see a changed -D value)
$(B)/gamelib_id.stamp: FORCE
	@mkdir -p $(dir $@)
	@echo '$(GAMELIB_ID)' | cmp -s - $@ || echo '$(GAMELIB_ID)' > $@
FORCE:
$(GB)/obj/tools/gamelib_entry.o: tools/gamelib_entry.c $(GAMELIB_SRCS) $(B)/gamelib_id.stamp $(wildcard $(GEN)/main_build_id.txt)
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -DGAMELIB_ID='"$(GAMELIB_FULL_ID)"' -c $< -o $@
# (the app's side: the generator id the libraries it loads must have; the game's build ID is added at run time)
$(B)/rt/gamelib.o: $(GAMELIB_SRCS) $(B)/gamelib_id.stamp
$(B)/rt/gamelib.o: RTFLAGS += -DGAMELIB_ID='"$(GAMELIB_ID)"'

$(B)/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

$(B)/rt/games/%.o: games/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

# SMAA (third_party/smaa, MIT): the reference shader as a C string for runtime/nvn/smaa_data.c (both backends build
# their passes from it); the non-ASCII bytes in its comments become '?', and its CRLF line ends plain LF (a CR left in
# the string literals ends them early on macOS clang)
$(B)/inc/smaa_hlsl.inc: third_party/smaa/SMAA.hlsl
	@mkdir -p $(dir $@)
	LC_ALL=C tr -d '\r' < $< | LC_ALL=C tr '\200-\377' '?' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/' > $@
$(B)/rt/nvn/smaa_data.o: $(B)/inc/smaa_hlsl.inc
$(B)/rt/nvn/smaa_data.o: RTFLAGS += -I$(B)/inc -Ithird_party/smaa/Textures

# The shader preparation's variant lists (runtime/nvn/shader_prep.h: no shader code, hashes and pipeline state only),
# one per game (games/<id>/shader_variants.txt, recorded in checkpoint runs: LARECOMP_RECORD_KEYS), as a table of C
# strings for runtime/nvn/shader_prep.c
VARIANT_LISTS := $(wildcard games/*/shader_variants.txt)
$(B)/inc/shader_variants.inc: $(VARIANT_LISTS) Makefile
	@mkdir -p $(dir $@)
	@: > $@
	@for f in $(VARIANT_LISTS); do id=$$(basename $$(dirname $$f)); \
	    echo "{\"$$id\"," >> $@; \
	    LC_ALL=C tr -d '\r' < $$f | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$$/\\n"/' >> $@; \
	    echo '""},' >> $@; done
$(B)/rt/nvn/shader_prep.o: $(B)/inc/shader_variants.inc
$(B)/rt/nvn/shader_prep.o: RTFLAGS += -I$(B)/inc
# the shader translator's id: part of the shader caches' tag (shader_cache_tag), so a changed translator rebuilds them
TRANSLATOR_SRCS := runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h
TRANSLATOR_ID := $(shell cat $(TRANSLATOR_SRCS) | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-12)
$(B)/rt/nvn/shader_prep.o: $(TRANSLATOR_SRCS)
$(B)/rt/nvn/shader_prep.o: RTFLAGS += -DSHADER_TRANSLATOR_ID='"$(TRANSLATOR_ID)"'

$(B)/rt/%.o: runtime/%.cpp $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OSFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

# linked to a temp file, then renamed over: a copy of the game still running keeps its (old) file - relinking in
# place gets running copies killed by macOS (code signature of the changed pages). The temp file keeps the real name
# (in a folder of its own): on Windows the import library records the name the game code library loads it by.
$(EXE): $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ) $(IMGUI_OBJ)
	@mkdir -p $(dir $@)link
	$(CXX) -o $(dir $@)link/$(notdir $@) $^ $(LDFLAGS)
	mv -f $(dir $@)link/$(notdir $@) $@
	@rmdir $(dir $@)link 2>/dev/null || true

# its id file (<library>.id) says what it was built from without loading it (runtime/gamelib.c)
$(GAMELIB): $(GEN_OBJ) | $(EXE)
	$(CC) $(GAMELIB_LDFLAGS) -o $@.tmp $^
	mv -f $@.tmp $@
	echo $(GAMELIB_FULL_ID) > $@.id

$(B)/rt/ui/%.o: runtime/ui/%.mm $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(UIFLAGS) -c $< -o $@

$(B)/imgui/%.o: $(IMGUI)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_%.o: $(IMGUI)/backends/imgui_impl_%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_metal.o: $(IMGUI)/backends/imgui_impl_metal.mm
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -fobjc-arc -c $< -o $@

# Python: .venv (macOS, Linux: bin/python, Windows: Scripts/python.exe)
PY := $(firstword $(wildcard .venv/bin/python) $(wildcard .venv/Scripts/python.exe) $(wildcard tools/venv/bin/python))

gen:
	$(PY) tools/gen_game.py $(GAME_DIR) $(GEN) $(GENSIMD)

gen-objs: $(GEN_OBJ)

# Runtime objects only (no generated code, no link): quick compile check
runtime-objs: $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ)

$(B)/rt/platform/windows_rc.o: runtime/platform/windows.rc docs/icon/icon.ico runtime/platform/windows.manifest
	@mkdir -p $(dir $@)
	$(WINDRES) -I docs/icon -I runtime/platform -O coff $< -o $@

.PHONY: all gen gen-objs runtime-objs FORCE

build/test_shaders: tools/test_shaders.m runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h
	clang -O1 -fobjc-arc -framework Metal -framework Foundation -o $@ tools/test_shaders.m runtime/nvn/maxwell/translate.c

# Every shader the game ships (romfs/system/shd), translated and compiled with Metal: no game needed to run
# (tools/shader_corpus.m). `make corpus` (MSL + Metal) - add CORPUS_ARGS=--glsl for the Vulkan GLSL translation.
build/shader_corpus: tools/shader_corpus.m runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h runtime/nvn/yaz0.h
	@mkdir -p $(dir $@)
	clang -O1 -fobjc-arc -framework Metal -framework Foundation -Iruntime/nvn/maxwell -Iruntime/nvn -I/opt/homebrew/opt/zstd/include \
	    tools/shader_corpus.m runtime/nvn/maxwell/translate.c -o $@ -L/opt/homebrew/opt/zstd/lib -lzstd
# Then the game's prepared pipelines into its Metal binary archive (cache/<game>/shaders.metalarchive: nx in
# preparation-only mode, games/<id>/shader_variants.txt and the shaders found in the game files), which the game loads.
# (the archive is built even when the check finds shaders it can't translate - ACNH's agl debug shaders - and corpus
# fails after it then; SKIP_CHECK=1: the archive alone)
corpus: build/shader_corpus $(EXE)
	@rc=0; [ -n "$(SKIP_CHECK)" ] || build/shader_corpus $(GAME_DIR)/romfs $(CORPUS_ARGS) || rc=$$?; \
	LARECOMP_SHADER_PREP_ONLY=1 LARECOMP_NO_LAUNCHER=1 LARECOMP_NO_AUDIO=1 $(EXE) $(GAME_DIR) && exit $$rc
.PHONY: corpus

# ---- iOS / iPadOS (docs/ios.md): `make ios IOS_GAMES="dread acnh"` builds build/<sdk>/nx.app with those games' code
# in it (Frameworks/<game>/game.dylib; default: GAME), which shows a game selection screen when it has several.
# `make ios-run` installs it in the booted Simulator and starts it there; `make ios-device IOS_DEVICE=<id>` on a device.
IOS_GAMES ?= $(GAME)
ios-libs:
	@for g in $(IOS_GAMES); do $(MAKE) PLATFORM=ios GAME=$$g gamelib || exit 1; done
ios: ios-libs
	$(MAKE) PLATFORM=ios ios-app
ios-run: ios-libs
	$(MAKE) PLATFORM=ios ios-install
ios-device: ios-libs
	$(MAKE) PLATFORM=ios IOS_SDK=iphoneos ios-device-install
gamelib: $(EXE) $(GAMELIB)
ifeq ($(PLATFORM),ios)
IOS_LIBS := $(foreach g,$(IOS_GAMES),$(APP)/Frameworks/$(g)/game.dylib)
# A device (IOS_SDK=iphoneos): IOS_PROFILE=<.mobileprovision for dev.dreadrecomp.nx> (Xcode makes one: docs/ios.md),
# IOS_SIGN=<signing identity, default the first "Apple Development" one>; signed with the profile's entitlements.
IOS_SIGN ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $$2}')
ios-app: $(EXE) $(APP)/Info.plist $(APP)/DejaVuSans.ttf $(APP)/DejaVuSans-Bold.ttf $(IOS_LIBS)
	@for f in $(APP)/Frameworks/*/game.dylib; do case " $(IOS_LIBS) " in *" $$f "*) ;; *) echo "removing $$f"; rm -rf "$$(dirname $$f)";; esac; done
ifeq ($(IOS_SDK),iphoneos)
	@[ -n "$(IOS_PROFILE)" ] || { echo "IOS_PROFILE=<provisioning profile> needed to sign for a device (docs/ios.md)"; exit 1; }
	cp "$(IOS_PROFILE)" $(APP)/embedded.mobileprovision
	security cms -D -i "$(IOS_PROFILE)" > $(B)/profile.plist && plutil -extract Entitlements xml1 -o $(B)/nx.entitlements $(B)/profile.plist
	codesign -f -s $(IOS_SIGN) $(IOS_LIBS)
	codesign -f -s $(IOS_SIGN) --entitlements $(B)/nx.entitlements $(APP)
else
	codesign -f -s - $(IOS_LIBS) $(APP) 2>&1 | grep -v "replacing existing signature" || true
endif
	@echo "$(APP)"
# (a device on USB: IOS_DEVICE=<its identifier from `xcrun devicectl list devices`>)
ios-device-install: ios-app
	xcrun devicectl device install app --device $(IOS_DEVICE) $(APP)
	xcrun devicectl device process launch --device $(IOS_DEVICE) --console --terminate-existing dev.dreadrecomp.nx
$(APP)/Info.plist: tools/ios/Info.plist Makefile
	@mkdir -p $(dir $@)
	sed -e 's/@PLATFORM@/$(if $(filter iphonesimulator,$(IOS_SDK)),iPhoneSimulator,iPhoneOS)/' -e 's/@IOS_MIN@/$(IOS_MIN)/' $< > $@
	plutil -convert binary1 $@
$(APP)/DejaVuSans.ttf $(APP)/DejaVuSans-Bold.ttf: $(APP)/%: third_party/fonts/DejaVu/%
	@mkdir -p $(dir $@)
	cp $< $@
$(APP)/Frameworks/%/game.dylib: $(B)/%/game.dylib
	@mkdir -p $(dir $@)
	cp $< $@ && cp $<.id $@.id
# (the Simulator: each game's files go in the app's Documents folder - a link to data/<game>, not a copy)
ios-install: ios-app
	xcrun simctl install booted $(APP)
	@docs=$$(xcrun simctl get_app_container booted dev.dreadrecomp.nx data) && mkdir -p "$$docs/Documents" && \
	    for g in $(IOS_GAMES); do [ -e "$$docs/Documents/$$g" ] || ln -s "$(abspath data)/$$g" "$$docs/Documents/$$g"; done
	xcrun simctl launch --console-pty booted dev.dreadrecomp.nx
endif
.PHONY: ios ios-libs ios-run ios-device gamelib ios-app ios-install ios-device-install
