VCS_HOME ?= /opt/Synopsys/vcs/V-2023.12-SP1
VCS      ?= $(VCS_HOME)/bin/vcs
SIMV     ?= simv
COV_SIMV ?= simv_cov

export VCS_HOME
export VCS_ARCH_OVERRIDE ?= linux

VCS_COMMON_OPTS := -full64 -sverilog -ntb_opts uvm-1.2 \
	-timescale=1ns/1ps -f filelist.f -top tb_top
VCS_OPTS := $(VCS_COMMON_OPTS) -o $(SIMV) -l compile.log
COV_TYPES := line+cond+fsm+tgl+branch+assert
RUN_OPTS ?= +UVM_TESTNAME=axi4l_smoke_test +UVM_VERBOSITY=UVM_MEDIUM

.PHONY: all smoke gpio_smoke v2_directed v2_random v3_pipelined v3_mid_reset v3_stress \
	v4_lifecycle_unit v4_channel_pipeline v4_response_order v4_depth3 v4_reset \
	v3_stress_depth3 c2_timing c2_checker_selftest c2 \
	regression coverage \
	coverage_clean compile run clean

all: smoke

smoke: compile run

compile:
	$(VCS) $(VCS_OPTS)

run:
	./$(SIMV) $(RUN_OPTS) -l smoke.log

gpio_smoke: compile
	./$(SIMV) +UVM_TESTNAME=gpio_agent_smoke_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l gpio_smoke.log

v2_directed: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_v2_directed_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l v2_directed.log

v2_random: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_v2_random_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l v2_random.log

v3_pipelined: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_pipelined_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l v3_pipelined.log

v3_mid_reset: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_mid_reset_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l v3_mid_reset.log

v3_stress: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_stress_test \
		+UVM_VERBOSITY=UVM_LOW -l v3_stress.log

v3_stress_depth3: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_stress_test +V3_STRESS_DEPTH=3 \
		+UVM_VERBOSITY=UVM_LOW -l v3_stress_depth3.log

c2_timing: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_timing_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l c2_timing.log

c2_checker_selftest: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_checker_selftest \
		+UVM_VERBOSITY=UVM_MEDIUM -l c2_checker_selftest.log

c2: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_timing_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l c2_timing.log
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_w1c_hw_collision_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l c2_w1c_hw_collision.log
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_checker_selftest \
		+UVM_VERBOSITY=UVM_MEDIUM -l c2_checker_selftest.log

v4_lifecycle_unit: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_lifecycle_unit_test \
		+UVM_VERBOSITY=UVM_MEDIUM -l v4_lifecycle_unit.log

v4_channel_pipeline: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_channel_pipeline_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=8 +UVM_VERBOSITY=UVM_MEDIUM -l v4_channel_pipeline.log

v4_response_order: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_response_order_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=4 +UVM_VERBOSITY=UVM_MEDIUM -l v4_response_order.log

v4_depth3: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_depth3_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=3 +UVM_VERBOSITY=UVM_MEDIUM -l v4_depth3.log

v4_reset: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_reset_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=2 +UVM_VERBOSITY=UVM_MEDIUM -l v4_reset.log

regression: compile
	./$(SIMV) +UVM_TESTNAME=axi4l_smoke_test +UVM_VERBOSITY=UVM_LOW \
		-l smoke.log
	./$(SIMV) +UVM_TESTNAME=gpio_agent_smoke_test +UVM_VERBOSITY=UVM_LOW \
		-l gpio_smoke.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_pipelined_test +UVM_VERBOSITY=UVM_LOW \
		-l v3_pipelined.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_mid_reset_test +UVM_VERBOSITY=UVM_LOW \
		-l v3_mid_reset.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v3_stress_test +UVM_VERBOSITY=UVM_LOW \
		-l v3_stress.log
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_v2_directed_test +UVM_VERBOSITY=UVM_LOW \
		-l v2_directed.log
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_v2_random_test +UVM_VERBOSITY=UVM_LOW \
		-l v2_random.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_lifecycle_unit_test +UVM_VERBOSITY=UVM_LOW \
		-l v4_lifecycle_unit.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_channel_pipeline_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=8 +UVM_VERBOSITY=UVM_LOW -l v4_channel_pipeline.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_response_order_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=4 +UVM_VERBOSITY=UVM_LOW -l v4_response_order.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_depth3_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=3 +UVM_VERBOSITY=UVM_LOW -l v4_depth3.log
	./$(SIMV) +UVM_TESTNAME=axi4l_v4_reset_test +V4_TEST_SLAVE \
		+V4_SLAVE_DEPTH=2 +UVM_VERBOSITY=UVM_LOW -l v4_reset.log
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_timing_test +UVM_VERBOSITY=UVM_LOW \
		-l c2_timing.log
	./$(SIMV) +UVM_TESTNAME=axi4l_gpio_w1c_hw_collision_test +UVM_VERBOSITY=UVM_LOW \
		-l c2_w1c_hw_collision.log
	./$(SIMV) +UVM_TESTNAME=axi4l_c2_checker_selftest +UVM_VERBOSITY=UVM_LOW \
		-l c2_checker_selftest.log

coverage: coverage_clean
	$(VCS) $(VCS_COMMON_OPTS) -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-o $(COV_SIMV) \
		-l compile_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_gpio_v2_directed_test \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name v2_directed -l v2_directed_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_gpio_v2_random_test \
		+ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) \
		-cm_dir coverage.vdb -cm_name v2_random -l v2_random_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_gpio_bit34_coverage_test \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name bit34_coverage -l bit34_coverage_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_gpio_w1c_hw_collision_test \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name w1c_hw_collision -l w1c_hw_collision_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_request_stall_test \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name request_stall -l request_stall_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_v3_stress_test \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name v3_stress -l v3_stress_cov.log
	./$(COV_SIMV) +UVM_TESTNAME=axi4l_v3_stress_test +V3_STRESS_DEPTH=3 \
		+UVM_VERBOSITY=UVM_LOW -cm $(COV_TYPES) -cm_dir coverage.vdb \
		-cm_name v3_stress_depth3 -l v3_stress_depth3_cov.log
	$(VCS_HOME)/bin/urg -dir coverage.vdb -report coverage_report

coverage_clean:
	rm -rf $(COV_SIMV) $(COV_SIMV).daidir coverage.vdb coverage_report \
		compile_cov.log v2_directed_cov.log v2_random_cov.log \
		bit34_coverage_cov.log w1c_hw_collision_cov.log \
		request_stall_cov.log v3_stress_cov.log v3_stress_depth3_cov.log

clean:
	rm -rf $(SIMV) $(SIMV).daidir $(COV_SIMV) $(COV_SIMV).daidir csrc \
		ucli.key vc_hdrs.h coverage.vdb coverage_report \
		compile.log smoke.log gpio_smoke.log v2_directed.log v2_random.log \
		v3_pipelined.log v3_mid_reset.log v3_stress.log v3_stress_depth3.log \
		v4_lifecycle_unit.log \
		v4_channel_pipeline.log v4_response_order.log v4_depth3.log v4_reset.log \
		c2_timing.log c2_w1c_hw_collision.log c2_checker_selftest.log \
		v3_stress_cov.log v3_stress_depth3_cov.log \
		compile_cov.log v2_directed_cov.log v2_random_cov.log \
		bit34_coverage.log bit34_coverage_cov.log \
		w1c_hw_collision.log w1c_hw_collision_cov.log \
		request_stall.log request_stall_cov.log \
		tr_db.log AN.DB DVEfiles

