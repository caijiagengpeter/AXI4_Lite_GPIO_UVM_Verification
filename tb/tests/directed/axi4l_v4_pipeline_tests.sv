class axi4l_v4_pipeline_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_v4_pipeline_seq)

  int unsigned num_per_direction = 8;
  axi4l_seq_item write_req[$];
  axi4l_seq_item read_req[$];
  axi4l_seq_item write_rsp[$];
  axi4l_seq_item read_rsp[$];
  bit write_order_observed = 1'b1;
  bit read_order_observed = 1'b1;

  function new(string name = "axi4l_v4_pipeline_seq"); super.new(name); endfunction

  task automatic issue_write(int unsigned index);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("v4_wr_%0d", index));
    start_item(req);
    req.access = AXI4L_WRITE;
    req.addr   = index[AXI4L_ADDR_WIDTH-1:0];
    req.data   = 32'h4400_0000 | index;
    req.strb   = '1;
    req.prot   = index[2:0];
    req.aw_delay = (index == 2) ? 20 : 0;
    req.w_delay  = (index == 0) ? 12 : 0;
    req.bready_delay = (index == 0) ? 24 : 0;
    req.ar_delay = 0;
    req.rready_delay = 0;
    req.set_transaction_id(100 + index);
    write_req.push_back(req);
    finish_item(req);
  endtask

  task automatic issue_read(int unsigned index);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("v4_rd_%0d", index));
    start_item(req);
    req.access = AXI4L_READ;
    req.addr   = index + 8;
    req.data   = '0;
    req.strb   = '1;
    req.prot   = index[2:0];
    req.aw_delay = 0;
    req.w_delay  = 0;
    req.bready_delay = 0;
    req.ar_delay = 0;
    req.rready_delay = (index == 0) ? 24 : 0;
    req.set_transaction_id(200 + index);
    read_req.push_back(req);
    finish_item(req);
  endtask

  task body();
    axi4l_seq_item rsp;
    axi4l_seq_item copy;
    set_response_queue_depth(-1);

    // Saturate write credits first, then prove read credits remain independent
    // while the oldest B response is deliberately backpressured.
    for (int i = 0; i < num_per_direction; i++) issue_write(i);
    for (int i = 0; i < num_per_direction; i++) issue_read(i);

    for (int i = 0; i < num_per_direction; i++) begin
      get_response(rsp, write_req[i].get_transaction_id());
      if (!$cast(copy, rsp.clone())) `uvm_fatal("V4_CLONE", "write response clone failed")
      write_rsp.push_back(copy);
      if (rsp.transaction_aborted || (rsp.resp !== 2'b00))
        `uvm_error("V4_WRITE_RSP", $sformatf("write[%0d] invalid response", i))
      if ((rsp.addr != write_req[i].addr) || (rsp.data != write_req[i].data) ||
          (rsp.get_sequence_id() != write_req[i].get_sequence_id()))
        `uvm_error("V4_WRITE_ASSOC", $sformatf("write[%0d] ID/payload mismatch", i))
      if ((i != 0) && (rsp.response_cycle <= write_rsp[i-1].response_cycle)) begin
        write_order_observed = 1'b0;
        `uvm_error("V4_WRITE_ORDER", "B responses were not published in direction order")
      end
    end

    for (int i = 0; i < num_per_direction; i++) begin
      get_response(rsp, read_req[i].get_transaction_id());
      if (!$cast(copy, rsp.clone())) `uvm_fatal("V4_CLONE", "read response clone failed")
      read_rsp.push_back(copy);
      if (rsp.transaction_aborted || (rsp.resp !== 2'b00))
        `uvm_error("V4_READ_RSP", $sformatf("read[%0d] invalid response", i))
      if (rsp.rdata !== ({{(AXI4L_DATA_WIDTH-AXI4L_ADDR_WIDTH){1'b0}}, rsp.addr}
                         ^ 32'h5a5a_1000))
        `uvm_error("V4_READ_DATA", $sformatf("read[%0d] data mismatch", i))
      if ((i != 0) && (rsp.response_cycle <= read_rsp[i-1].response_cycle)) begin
        read_order_observed = 1'b0;
        `uvm_error("V4_READ_ORDER", "R responses were not published in direction order")
      end
    end

    if (num_per_direction >= 3) begin
      if (!(write_rsp[1].aw_cycle < write_rsp[0].w_cycle))
        `uvm_error("V4_NO_CROSS_TXN_OVERLAP",
          $sformatf("AW_B=%0d was not before W_A=%0d",
                    write_rsp[1].aw_cycle, write_rsp[0].w_cycle))
      if (!(write_rsp[2].w_cycle < write_rsp[2].aw_cycle))
        `uvm_error("V4_NO_W_BEFORE_AW",
          $sformatf("W_C=%0d was not before AW_C=%0d",
                    write_rsp[2].w_cycle, write_rsp[2].aw_cycle))
      `uvm_info("V4_CHANNEL_PIPELINE_PROOF",
        $sformatf("AW_B=%0d < W_A=%0d; W_C=%0d < AW_C=%0d",
                  write_rsp[1].aw_cycle, write_rsp[0].w_cycle,
                  write_rsp[2].w_cycle, write_rsp[2].aw_cycle), UVM_NONE)
    end
  endtask
endclass

class axi4l_v4_agent_test_base extends uvm_test;
  `uvm_component_utils(axi4l_v4_agent_test_base)
  axi4l_agent agent;
  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  int unsigned configured_depth = 8;

  covergroup v4_depth_order_cg with function sample(
    int write_highwater, int read_highwater,
    bit write_ordered, bit read_ordered
  );
    option.per_instance = 1;
    cp_write_highwater: coverpoint write_highwater {
      bins depth2 = {2}; bins depth3 = {3}; bins depth4 = {4}; bins depth8 = {8};
    }
    cp_read_highwater: coverpoint read_highwater {
      bins depth2 = {2}; bins depth3 = {3}; bins depth4 = {4}; bins depth8 = {8};
    }
    cp_write_order: coverpoint write_ordered { bins ordered = {1}; }
    cp_read_order: coverpoint read_ordered { bins ordered = {1}; }
  endgroup

  covergroup v4_reset_context_cg with function sample(int scenario);
    option.per_instance = 1;
    cp_context: coverpoint scenario {
      bins aw_only = {0}; bins w_only = {1}; bins pending_b = {2};
      bins pending_r = {3}; bins credit_wait = {4};
      bins normal_before_publication = {5}; bins recovery = {6};
    }
  endgroup

  function new(string name = "axi4l_v4_agent_test_base", uvm_component parent = null);
    super.new(name, parent);
    v4_depth_order_cg = new;
    v4_reset_context_cg = new;
  endfunction

  function void sample_v4_depth_order(bit write_ordered,
                                      bit read_ordered);
    v4_depth_order_cg.sample(vif.test_max_write_outstanding,
                             vif.test_max_read_outstanding,
                             write_ordered, read_ordered);
  endfunction

  function void sample_v4_reset_context(int scenario);
    v4_reset_context_cg.sample(scenario);
  endfunction

  function void build_phase(uvm_phase phase);
    uvm_config_db#(uvm_active_passive_enum)::set(this, "agent", "is_active", UVM_ACTIVE);
    uvm_config_db#(bit)::set(this, "agent.driver", "v4_mode", 1'b1);
    uvm_config_db#(int unsigned)::set(this, "agent.driver",
                                      "max_write_outstanding", configured_depth);
    uvm_config_db#(int unsigned)::set(this, "agent.driver",
                                      "max_read_outstanding", configured_depth);
    super.build_phase(phase);
    agent = axi4l_agent::type_id::create("agent", this);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("V4_NOVIF", "v4 test did not receive the selected interface")
  endfunction

  task wait_for_startup();
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (3) @(vif.mon_cb);
  endtask

  task automatic check_stability(ref bit stop,
                                 output int unsigned stall_observations);
    bit prev_aw_stall, prev_w_stall, prev_ar_stall;
    bit [AXI4L_ADDR_WIDTH-1:0] prev_awaddr, prev_araddr;
    bit [2:0] prev_awprot, prev_arprot;
    bit [AXI4L_DATA_WIDTH-1:0] prev_wdata;
    bit [AXI4L_DATA_WIDTH/8-1:0] prev_wstrb;
    stall_observations = 0;
    while (!stop) begin
      @(vif.mon_cb);
      if (vif.mon_cb.ARESETN !== 1'b1) begin
        prev_aw_stall = 0; prev_w_stall = 0; prev_ar_stall = 0;
        continue;
      end
      if (prev_aw_stall && (!vif.mon_cb.AWVALID ||
          (vif.mon_cb.AWADDR != prev_awaddr) || (vif.mon_cb.AWPROT != prev_awprot)))
        `uvm_error("V4_AW_STABILITY", "AW payload/VALID changed while stalled")
      if (prev_w_stall && (!vif.mon_cb.WVALID ||
          (vif.mon_cb.WDATA != prev_wdata) || (vif.mon_cb.WSTRB != prev_wstrb)))
        `uvm_error("V4_W_STABILITY", "W payload/VALID changed while stalled")
      if (prev_ar_stall && (!vif.mon_cb.ARVALID ||
          (vif.mon_cb.ARADDR != prev_araddr) || (vif.mon_cb.ARPROT != prev_arprot)))
        `uvm_error("V4_AR_STABILITY", "AR payload/VALID changed while stalled")
      prev_aw_stall = vif.mon_cb.AWVALID && !vif.mon_cb.AWREADY;
      prev_w_stall  = vif.mon_cb.WVALID  && !vif.mon_cb.WREADY;
      prev_ar_stall = vif.mon_cb.ARVALID && !vif.mon_cb.ARREADY;
      if (prev_aw_stall || prev_w_stall || prev_ar_stall ||
          (vif.mon_cb.BVALID && !vif.mon_cb.BREADY) ||
          (vif.mon_cb.RVALID && !vif.mon_cb.RREADY))
        stall_observations++;
      prev_awaddr = vif.mon_cb.AWADDR; prev_awprot = vif.mon_cb.AWPROT;
      prev_wdata  = vif.mon_cb.WDATA;  prev_wstrb  = vif.mon_cb.WSTRB;
      prev_araddr = vif.mon_cb.ARADDR; prev_arprot = vif.mon_cb.ARPROT;
    end
  endtask
endclass

class axi4l_v4_channel_pipeline_test extends axi4l_v4_agent_test_base;
  `uvm_component_utils(axi4l_v4_channel_pipeline_test)
  function new(string name = "axi4l_v4_channel_pipeline_test", uvm_component parent = null);
    super.new(name, parent); configured_depth = 8;
  endfunction
  task run_phase(uvm_phase phase);
    axi4l_v4_pipeline_seq seq;
    bit stop;
    int unsigned stalls;
    phase.raise_objection(this);
    wait_for_startup();
    seq = axi4l_v4_pipeline_seq::type_id::create("seq");
    seq.num_per_direction = 8;
    stop = 1'b0;
    fork
      check_stability(stop, stalls);
      begin
        seq.start(agent.sequencer);
        agent.driver.wait_for_v4_idle();
        stop = 1'b1;
      end
    join
    if (stalls == 0) `uvm_error("V4_NO_STALL", "directed slave produced no stall observation")
    if ((vif.test_max_write_outstanding < 8) ||
        (vif.test_max_read_outstanding < 8))
      `uvm_error("V4_DEPTH_PROOF",
        $sformatf("actual depths write=%0d read=%0d, expected 8/8",
                  vif.test_max_write_outstanding,
                  vif.test_max_read_outstanding))
    if ((agent.driver.v4_dispatch_count != 16) ||
        (agent.driver.v4_publish_count != 16))
      `uvm_error("V4_EXACTLY_ONCE", "dispatch/publish counts are not 16/16")
    `uvm_info("V4_DEPTH_PROOF",
      $sformatf("controlled slave actual max outstanding write=%0d read=%0d stalls=%0d",
                vif.test_max_write_outstanding,
                vif.test_max_read_outstanding, stalls), UVM_NONE)
    sample_v4_depth_order(seq.write_order_observed, seq.read_order_observed);
    phase.drop_objection(this);
  endtask
endclass

class axi4l_v4_response_order_test extends axi4l_v4_agent_test_base;
  `uvm_component_utils(axi4l_v4_response_order_test)
  function new(string name = "axi4l_v4_response_order_test", uvm_component parent = null);
    super.new(name, parent); configured_depth = 4;
  endfunction
  task run_phase(uvm_phase phase);
    axi4l_v4_pipeline_seq seq;
    phase.raise_objection(this);
    wait_for_startup();
    seq = axi4l_v4_pipeline_seq::type_id::create("order_seq");
    seq.num_per_direction = 4;
    seq.start(agent.sequencer);
    agent.driver.wait_for_v4_idle();
    if ((agent.driver.v4_b_handshake_count != 4) ||
        (agent.driver.v4_r_handshake_count != 4))
      `uvm_error("V4_ORDER_COUNT", "B/R handshake counts are not 4/4")
    if ((vif.test_max_write_outstanding < 4) ||
        (vif.test_max_read_outstanding < 4))
      `uvm_error("V4_DEPTH4_PROOF", "controlled slave did not reach actual 4/4 depth")
    sample_v4_depth_order(seq.write_order_observed, seq.read_order_observed);
    phase.drop_objection(this);
  endtask
endclass

class axi4l_v4_depth3_test extends axi4l_v4_agent_test_base;
  `uvm_component_utils(axi4l_v4_depth3_test)
  function new(string name = "axi4l_v4_depth3_test", uvm_component parent = null);
    super.new(name, parent); configured_depth = 3;
  endfunction
  task run_phase(uvm_phase phase);
    axi4l_v4_pipeline_seq seq;
    phase.raise_objection(this);
    wait_for_startup();
    seq = axi4l_v4_pipeline_seq::type_id::create("depth3_seq");
    seq.num_per_direction = 3;
    seq.start(agent.sequencer);
    agent.driver.wait_for_v4_idle();
    if ((vif.test_max_write_outstanding < 3) ||
        (vif.test_max_read_outstanding < 3))
      `uvm_error("V4_DEPTH3_PROOF", "controlled slave did not reach actual 3/3 depth")
    sample_v4_depth_order(seq.write_order_observed, seq.read_order_observed);
    phase.drop_objection(this);
  endtask
endclass
