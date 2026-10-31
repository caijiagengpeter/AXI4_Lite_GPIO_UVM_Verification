typedef enum int unsigned {
  V4_RESET_AW_ONLY,
  V4_RESET_W_ONLY,
  V4_RESET_PENDING_B,
  V4_RESET_PENDING_R,
  V4_RESET_CREDIT_WAIT,
  V4_RESET_NORMAL_UNPUBLISHED,
  V4_RESET_RECOVERY,
  V4_RESET_DEPTH2_BOTH
} axi4l_v4_reset_scenario_e;

class axi4l_v4_reset_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_v4_reset_seq)
  axi4l_v4_reset_scenario_e scenario;
  int unsigned base_id;
  axi4l_seq_item requests[$];
  bit expect_abort[$];

  function new(string name = "axi4l_v4_reset_seq"); super.new(name); endfunction

  task automatic issue(axi4l_access_e access,
                       int unsigned aw_delay, int unsigned w_delay,
                       int unsigned ar_delay, int unsigned response_delay,
                       bit aborted);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create($sformatf("reset_req_%0d", requests.size()));
    start_item(req);
    req.access = access;
    req.addr   = requests.size() + 1;
    req.data   = 32'hab00_0000 | base_id | requests.size();
    req.strb   = '1;
    req.prot   = 3'b000;
    req.aw_delay = aw_delay;
    req.w_delay  = w_delay;
    req.ar_delay = ar_delay;
    req.bready_delay = (access == AXI4L_WRITE) ? response_delay : 0;
    req.rready_delay = (access == AXI4L_READ)  ? response_delay : 0;
    req.set_transaction_id(base_id + requests.size());
    requests.push_back(req);
    expect_abort.push_back(aborted);
    finish_item(req);
  endtask

  task body();
    axi4l_seq_item rsp;
    set_response_queue_depth(-1);
    case (scenario)
      V4_RESET_AW_ONLY:
        issue(AXI4L_WRITE, 0, 40, 0, 0, 1'b1);
      V4_RESET_W_ONLY:
        issue(AXI4L_WRITE, 40, 0, 0, 0, 1'b1);
      V4_RESET_PENDING_B:
        issue(AXI4L_WRITE, 0, 0, 0, 80, 1'b1);
      V4_RESET_PENDING_R:
        issue(AXI4L_READ, 0, 0, 0, 80, 1'b1);
      V4_RESET_CREDIT_WAIT: begin
        issue(AXI4L_WRITE, 0, 0, 0, 100, 1'b1);
        issue(AXI4L_WRITE, 0, 0, 0, 0,   1'b1);
        issue(AXI4L_WRITE, 0, 0, 0, 0,   1'b1);
      end
      V4_RESET_NORMAL_UNPUBLISHED:
        issue(AXI4L_WRITE, 0, 0, 0, 0, 1'b0);
      V4_RESET_DEPTH2_BOTH: begin
        issue(AXI4L_WRITE, 0, 0, 0, 80, 1'b1);
        issue(AXI4L_WRITE, 0, 0, 0, 80, 1'b1);
        issue(AXI4L_READ,  0, 0, 0, 80, 1'b1);
        issue(AXI4L_READ,  0, 0, 0, 80, 1'b1);
      end
      V4_RESET_RECOVERY: begin
        issue(AXI4L_WRITE, 0, 0, 0, 0, 1'b0);
        issue(AXI4L_READ,  0, 0, 0, 0, 1'b0);
      end
    endcase

    foreach (requests[i]) begin
      get_response(rsp, requests[i].get_transaction_id());
      if (rsp.get_sequence_id() != requests[i].get_sequence_id())
        `uvm_error("V4_RESET_SEQ_ID", "response lost originating sequence ID")
      if (expect_abort[i]) begin
        if (!rsp.transaction_aborted || (rsp.resp !== 2'bxx) ||
            (rsp.rdata !== {AXI4L_DATA_WIDTH{1'bx}}))
          `uvm_error("V4_RESET_ABORT", $sformatf("request %0d abort contract failed", i))
      end else if (rsp.transaction_aborted || (rsp.resp !== 2'b00)) begin
        `uvm_error("V4_RESET_FALSE_ABORT", $sformatf("request %0d should be NORMAL", i))
      end
    end
  endtask
endclass

class axi4l_v4_reset_test extends axi4l_v4_agent_test_base;
  `uvm_component_utils(axi4l_v4_reset_test)
  int unsigned observed_max_write_outstanding;
  int unsigned observed_max_read_outstanding;
  function new(string name = "axi4l_v4_reset_test", uvm_component parent = null);
    super.new(name, parent); configured_depth = 2;
  endfunction

  task automatic pulse_reset(string scenario_name,
                             axi4l_v4_reset_scenario_e observed_context);
    sample_v4_reset_context(observed_context);
    if (vif.test_max_write_outstanding > observed_max_write_outstanding)
      observed_max_write_outstanding = vif.test_max_write_outstanding;
    if (vif.test_max_read_outstanding > observed_max_read_outstanding)
      observed_max_read_outstanding = vif.test_max_read_outstanding;
    vif.ARESETN <= 1'b0;
    repeat (2) @(vif.mon_cb);
    if (vif.mon_cb.ARESETN !== 1'b0)
      `uvm_error("V4_RESET_LEVEL", $sformatf("%s reset was not sampled low", scenario_name))
    if (vif.mon_cb.AWVALID || vif.mon_cb.WVALID || vif.mon_cb.ARVALID ||
        vif.mon_cb.BREADY || vif.mon_cb.RREADY)
      `uvm_error("V4_RESET_PINS",
        $sformatf("%s pin owners were not quiescent during reset", scenario_name))
    @(vif.mon_cb);
    vif.ARESETN <= 1'b1;
    do @(vif.mon_cb); while (vif.mon_cb.ARESETN !== 1'b1);
    repeat (2) @(vif.mon_cb);
  endtask

  task automatic inject_reset(axi4l_v4_reset_scenario_e scenario,
                              longint unsigned b_before);
    case (scenario)
      V4_RESET_AW_ONLY:
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY && !vif.mon_cb.WVALID) begin
            pulse_reset("aw_only", scenario); return;
          end
        end
      V4_RESET_W_ONLY:
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.WVALID && vif.mon_cb.WREADY && !vif.mon_cb.AWVALID) begin
            pulse_reset("w_only", scenario); return;
          end
        end
      V4_RESET_PENDING_B:
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.BVALID && !vif.mon_cb.BREADY) begin
            pulse_reset("pending_b", scenario); return;
          end
        end
      V4_RESET_PENDING_R:
        forever begin
          @(vif.mon_cb);
          if (vif.mon_cb.RVALID && !vif.mon_cb.RREADY) begin
            pulse_reset("pending_r", scenario); return;
          end
        end
      V4_RESET_CREDIT_WAIT: begin
        longint unsigned epoch;
        bit reset_active;
        int unsigned wa, ra, wo, ro, registry_count, terminal_depth;
        forever begin
          @(vif.mon_cb);
          agent.driver.v4_lifecycle.get_snapshot(
            epoch, reset_active, wa, ra, wo, ro,
            registry_count, terminal_depth);
          if ((wo == 2) && (wa == 0) &&
              (agent.sequencer.get_current_item() != null)) begin
            pulse_reset("credit_wait", scenario);
            return;
          end
        end
      end
      V4_RESET_NORMAL_UNPUBLISHED: begin
        wait (agent.driver.v4_b_handshake_count > b_before);
        pulse_reset("normal_unpublished", scenario);
        agent.driver.v4_publisher_hold = 1'b0;
      end
      V4_RESET_DEPTH2_BOTH: begin
        forever begin
          @(vif.mon_cb);
          if ((vif.test_max_write_outstanding >= 2) &&
              (vif.test_max_read_outstanding >= 2) &&
              vif.mon_cb.BVALID && !vif.mon_cb.BREADY &&
              vif.mon_cb.RVALID && !vif.mon_cb.RREADY) begin
            pulse_reset("depth2_both", scenario);
            return;
          end
        end
      end
      default: ;
    endcase
  endtask

  task automatic run_one(axi4l_v4_reset_scenario_e scenario,
                         int unsigned index);
    axi4l_v4_reset_seq seq;
    longint unsigned publish_before;
    longint unsigned b_before;
    seq = axi4l_v4_reset_seq::type_id::create($sformatf("reset_seq_%0d", index));
    seq.scenario = scenario;
    seq.base_id  = 1000 + (index * 10);
    publish_before = agent.driver.v4_publish_count;
    b_before = agent.driver.v4_b_handshake_count;
    if (scenario == V4_RESET_NORMAL_UNPUBLISHED)
      agent.driver.v4_publisher_hold = 1'b1;
    fork
      seq.start(agent.sequencer);
      inject_reset(scenario, b_before);
    join
    agent.driver.wait_for_v4_idle();
    if ((agent.driver.v4_publish_count - publish_before) != seq.requests.size())
      `uvm_error("V4_RESET_EXACTLY_ONCE",
        $sformatf("scenario %0d published %0d responses for %0d requests",
                  scenario, agent.driver.v4_publish_count - publish_before,
                  seq.requests.size()))
    `uvm_info("V4_RESET_SCENARIO_PASS",
      $sformatf("scenario=%0d requests=%0d responses=%0d",
                scenario, seq.requests.size(),
                agent.driver.v4_publish_count - publish_before), UVM_NONE)
  endtask

  task automatic run_recovery(int unsigned index);
    axi4l_v4_reset_seq seq;
    seq = axi4l_v4_reset_seq::type_id::create($sformatf("recovery_%0d", index));
    seq.scenario = V4_RESET_RECOVERY;
    seq.base_id = 2000 + (index * 10);
    seq.start(agent.sequencer);
    agent.driver.wait_for_v4_idle();
    sample_v4_reset_context(V4_RESET_RECOVERY);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    wait_for_startup();
    run_one(V4_RESET_AW_ONLY,             1); run_recovery(1);
    run_one(V4_RESET_W_ONLY,              2); run_recovery(2);
    run_one(V4_RESET_PENDING_B,           3); run_recovery(3);
    run_one(V4_RESET_PENDING_R,           4); run_recovery(4);
    run_one(V4_RESET_CREDIT_WAIT,         5); run_recovery(5);
    run_one(V4_RESET_NORMAL_UNPUBLISHED,  6); run_recovery(6);
    run_one(V4_RESET_DEPTH2_BOTH,         7); run_recovery(7);
    if (vif.test_max_write_outstanding > observed_max_write_outstanding)
      observed_max_write_outstanding = vif.test_max_write_outstanding;
    if (vif.test_max_read_outstanding > observed_max_read_outstanding)
      observed_max_read_outstanding = vif.test_max_read_outstanding;
    v4_depth_order_cg.sample(observed_max_write_outstanding,
                             observed_max_read_outstanding, 1'b1, 1'b1);
    if ((observed_max_write_outstanding < 2) ||
        (observed_max_read_outstanding < 2))
      `uvm_error("V4_RESET_DEPTH2_MISSED",
        $sformatf("reset matrix reached only write=%0d read=%0d",
          observed_max_write_outstanding, observed_max_read_outstanding))
    `uvm_info("V4_RESET_DEPTH_PROOF",
      $sformatf("controlled slave reset scenarios observed max outstanding write=%0d read=%0d",
        observed_max_write_outstanding, observed_max_read_outstanding), UVM_NONE)
    `uvm_info("V4_RESET_PASS",
      "AW-only/W-only/pending B/pending R/credit wait/normal-unpublished/real depth2-both and recovery completed",
      UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass
