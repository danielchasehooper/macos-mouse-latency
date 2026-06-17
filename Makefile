APP = input-latency
SRCS = main.m

run: $(APP)
	MTL_HUD_ENABLED=1 MTL_HUD_ENCODER_TIMING_ENABLED=1 MTL_HUD_ELEMENTS=device,rosetta,layersize,layerscale,memory,fps,frameinterval,gputime,thermal,frameintervalgraph,presentdelay,frameintervalhistogram,metalcpu,gputimeline,shaders,framenumber,disk,fpsgraph,toplabeledcommandbuffers,toplabeledencoders ./$(APP)

build: $(APP)

$(APP): $(SRCS)
	clang -O2 -fobjc-arc -Wall \
	-framework Cocoa -framework Metal -framework QuartzCore \
	-o $@ $^


clean:
	rm -f $(APP)

.PHONY: clean
