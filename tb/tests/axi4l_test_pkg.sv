package axi4l_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axi4l_gpio_tb_cfg_pkg::GPIO_NIN;
  import axi4l_gpio_tb_cfg_pkg::GPIO_NOUT;
  import axi4l_gpio_tb_cfg_pkg::GPIO_DEFAULT_OUTPUT;
  import axi4l_gpio_tb_cfg_pkg::GPIO_OPT_SKIDBUFFER;
  import axi4l_gpio_tb_cfg_pkg::GPIO_OPT_LOWPOWER;
  import axi4l_agent_pkg::*;
  import axi4l_v4_lifecycle_pkg::*;
  import gpio_agent_pkg::*;
  import axi4l_env_pkg::*;

  `include "axi4l_single_access_seq.sv"
  `include "axi4l_v3_pipeline_seq.sv"
  `include "axi4l_v3_mid_reset_seq.sv"
  `include "axi4l_v3_stress_seq.sv"
  `include "gpio_single_level_seq.sv"
  `include "axi4l_gpio_v2_base_test.sv"
  `include "directed/axi4l_smoke_test.sv"
  `include "directed/gpio_agent_smoke_test.sv"
  `include "directed/axi4l_gpio_bit34_coverage_test.sv"
  `include "directed/axi4l_gpio_w1c_hw_collision_test.sv"
  `include "directed/axi4l_request_stall_test.sv"
  `include "directed/axi4l_v3_pipelined_test.sv"
  `include "directed/axi4l_v3_mid_reset_test.sv"
  `include "directed/axi4l_v3_stress_test.sv"
  `include "directed/axi4l_v4_lifecycle_unit_test.sv"
  `include "directed/axi4l_v4_pipeline_tests.sv"
  `include "directed/axi4l_v4_reset_test.sv"
  `include "directed/axi4l_c2_tests.sv"
  `include "directed/axi4l_gpio_v2_directed_test.sv"
  `include "directed/axi4l_c3_2_coverage_test.sv"
  `include "directed/axi4l_c3_3_parameter_test.sv"
  `include "random/axi4l_gpio_v2_random_test.sv"
endpackage

