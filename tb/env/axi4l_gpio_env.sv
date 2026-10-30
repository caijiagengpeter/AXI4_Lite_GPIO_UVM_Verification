class axi4l_gpio_env extends uvm_env;
  `uvm_component_utils(axi4l_gpio_env)

  axi4l_agent           axi_agent;
  gpio_agent            gpio_agent_h;
  axi4l_gpio_scoreboard scoreboard;
  axi4l_gpio_coverage   coverage;

  function new(string name = "axi4l_gpio_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    axi_agent    = axi4l_agent::type_id::create("axi4l_agent", this);
    gpio_agent_h = gpio_agent::type_id::create("gpio_agent", this);
    scoreboard   = axi4l_gpio_scoreboard::type_id::create("scoreboard", this);
    coverage     = axi4l_gpio_coverage::type_id::create("coverage", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    axi_agent.monitor.request_ap.connect(scoreboard.axi_req_imp);
    axi_agent.monitor.response_ap.connect(scoreboard.axi_rsp_imp);
    gpio_agent_h.monitor.ap.connect(scoreboard.gpio_imp);
    axi_agent.monitor.request_ap.connect(coverage.axi_req_imp);
    gpio_agent_h.monitor.ap.connect(coverage.gpio_imp);
  endfunction
endclass
