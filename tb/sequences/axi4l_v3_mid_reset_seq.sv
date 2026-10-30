typedef enum int unsigned {
  V3_MID_RESET_PARTIAL_WRITE,
  V3_MID_RESET_PENDING_B,
  V3_MID_RESET_PENDING_R,
  V3_MID_RESET_MULTI_RW,
  V3_MID_RESET_CREDIT_WAIT,
  V3_MID_RESET_COMPLETED_BOUNDARY,
  V3_MID_RESET_RECOVERY
} axi4l_v3_mid_reset_scenario_e;

class axi4l_v3_mid_reset_seq extends uvm_sequence #(axi4l_seq_item);
  `uvm_object_utils(axi4l_v3_mid_reset_seq)

  localparam logic [1:0] AXI_OKAY = 2'b00;

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;
  axi4l_v3_mid_reset_scenario_e scenario;
  int unsigned                 base_transaction_id = 100;
  logic [AXI4L_DATA_WIDTH-1:0] recovery_data = 32'h1234_5678;

  axi4l_seq_item requests[$];
  bit             expect_abort[$];
  bit             check_read_data[$];
  logic [AXI4L_DATA_WIDTH-1:0] expected_read_data[$];
  bit             response_seen[$];
  int unsigned    response_count;

  function new(string name = "axi4l_v3_mid_reset_seq");
    super.new(name);
  endfunction

  function string scenario_name();
    case (scenario)
      V3_MID_RESET_PARTIAL_WRITE:      return "partial_write";
      V3_MID_RESET_PENDING_B:          return "pending_b";
      V3_MID_RESET_PENDING_R:          return "pending_r";
      V3_MID_RESET_MULTI_RW:           return "multi_rw";
      V3_MID_RESET_CREDIT_WAIT:        return "credit_wait";
      V3_MID_RESET_COMPLETED_BOUNDARY: return "completed_boundary";
      V3_MID_RESET_RECOVERY:           return "recovery";
      default:                         return "unknown";
    endcase
  endfunction

  task automatic register_request(axi4l_seq_item req,
                                  bit aborted,
                                  bit check_data = 1'b0,
                                  logic [AXI4L_DATA_WIDTH-1:0] exp_data = 'x);
    // Supplying deterministic transaction IDs before finish_item() makes the
    // response-routing proof independent of UVM's internal auto-numbering.
    req.set_transaction_id(base_transaction_id + requests.size());
    requests.push_back(req);
    expect_abort.push_back(aborted);
    check_read_data.push_back(check_data);
    expected_read_data.push_back(exp_data);
    response_seen.push_back(1'b0);
    finish_item(req);
  endtask

  task automatic issue_write(logic [AXI4L_ADDR_WIDTH-1:0] addr,
                             logic [AXI4L_DATA_WIDTH-1:0] data,
                             int unsigned aw_delay,
                             int unsigned w_delay,
                             int unsigned bready_delay,
                             bit aborted);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create(
      $sformatf("write_req_%0d", requests.size()));
    start_item(req);
    req.access         = AXI4L_WRITE;
    req.addr           = addr;
    req.data           = data;
    req.strb           = '1;
    req.prot           = 3'b000;
    req.aw_delay       = aw_delay;
    req.w_delay        = w_delay;
    req.ar_delay       = 0;
    req.bready_delay   = bready_delay;
    req.rready_delay   = 0;
    register_request(req, aborted);
  endtask

  task automatic issue_read(logic [AXI4L_ADDR_WIDTH-1:0] addr,
                            int unsigned ar_delay,
                            int unsigned rready_delay,
                            bit aborted,
                            bit check_data = 1'b0,
                            logic [AXI4L_DATA_WIDTH-1:0] exp_data = 'x);
    axi4l_seq_item req;
    req = axi4l_seq_item::type_id::create(
      $sformatf("read_req_%0d", requests.size()));
    start_item(req);
    req.access         = AXI4L_READ;
    req.addr           = addr;
    req.data           = '0;
    req.strb           = '1;
    req.prot           = 3'b000;
    req.aw_delay       = 0;
    req.w_delay        = 0;
    req.ar_delay       = ar_delay;
    req.bready_delay   = 0;
    req.rready_delay   = rready_delay;
    register_request(req, aborted, check_data, exp_data);
  endtask

  virtual function void response_handler(uvm_sequence_item response);
    axi4l_seq_item rsp;
    int matched_index;

    response_count++;
    if (!$cast(rsp, response)) begin
      `uvm_error("V3_RESET_RSP_TYPE", "response was not an axi4l_seq_item")
      return;
    end

    matched_index = -1;
    foreach (requests[i]) begin
      if (requests[i].get_transaction_id() == rsp.get_transaction_id()) begin
        matched_index = i;
        break;
      end
    end

    if (matched_index < 0) begin
      `uvm_error("V3_RESET_UNKNOWN_RSP",
        $sformatf("%s received unknown tr_id=%0d",
                  scenario_name(), rsp.get_transaction_id()))
      return;
    end

    if (response_seen[matched_index])
      `uvm_error("V3_RESET_DUP_RSP",
        $sformatf("%s received duplicate response for tr_id=%0d",
                  scenario_name(), rsp.get_transaction_id()))
    response_seen[matched_index] = 1'b1;

    if (rsp.get_sequence_id() != requests[matched_index].get_sequence_id())
      `uvm_error("V3_RESET_SEQ_ID",
        $sformatf("%s tr_id=%0d response seq_id=%0d expected=%0d",
                  scenario_name(), rsp.get_transaction_id(),
                  rsp.get_sequence_id(),
                  requests[matched_index].get_sequence_id()))

    if (expect_abort[matched_index]) begin
      if (!rsp.transaction_aborted)
        `uvm_error("V3_RESET_MISSING_ABORT",
          $sformatf("%s tr_id=%0d returned a normal response",
                    scenario_name(), rsp.get_transaction_id()))
      if (rsp.resp !== 2'bxx)
        `uvm_error("V3_RESET_ABORT_RESP_VALID",
          $sformatf("%s tr_id=%0d abort response carried resp=%02b",
                    scenario_name(), rsp.get_transaction_id(), rsp.resp))
      if (rsp.rdata !== {AXI4L_DATA_WIDTH{1'bx}})
        `uvm_error("V3_RESET_ABORT_DATA_VALID",
          $sformatf("%s tr_id=%0d abort response carried rdata=0x%08h",
                    scenario_name(), rsp.get_transaction_id(), rsp.rdata))
    end else begin
      if (rsp.transaction_aborted)
        `uvm_error("V3_RESET_FALSE_ABORT",
          $sformatf("%s tr_id=%0d was already complete but was aborted",
                    scenario_name(), rsp.get_transaction_id()))
      if (rsp.resp !== AXI_OKAY)
        `uvm_error("V3_RESET_NORMAL_RESP",
          $sformatf("%s tr_id=%0d returned resp=%02b",
                    scenario_name(), rsp.get_transaction_id(), rsp.resp))
      if (check_read_data[matched_index] &&
          (rsp.rdata !== expected_read_data[matched_index]))
        `uvm_error("V3_RESET_RECOVERY_DATA",
          $sformatf("%s tr_id=%0d read 0x%08h expected 0x%08h",
                    scenario_name(), rsp.get_transaction_id(), rsp.rdata,
                    expected_read_data[matched_index]))
    end

    `uvm_info("V3_RESET_RSP",
      $sformatf("scenario=%s index=%0d seq_id=%0d tr_id=%0d aborted=%0b resp=%02b rdata=0x%08h count=%0d/%0d",
                scenario_name(), matched_index, rsp.get_sequence_id(),
                rsp.get_transaction_id(), rsp.transaction_aborted, rsp.resp,
                rsp.rdata, response_count, requests.size()), UVM_NONE)
  endfunction

  task body();
    if (vif == null)
      `uvm_fatal("V3_RESET_NOVIF", "mid-reset sequence did not receive vif")

    use_response_handler(1'b1);
    case (scenario)
      V3_MID_RESET_PARTIAL_WRITE:
        // AW is accepted first.  W has not yet been presented when the test
        // observes the AW handshake and asserts reset.
        issue_write(5'h00, 32'ha11a_0001, 0, 40, 0, 1'b1);

      V3_MID_RESET_PENDING_B:
        issue_write(5'h00, 32'hb00b_0002, 0, 0, 80, 1'b1);

      V3_MID_RESET_PENDING_R:
        issue_read(5'h00, 0, 80, 1'b1);

      V3_MID_RESET_MULTI_RW: begin
        // The first response on each side is deliberately backpressured.  The
        // DUT's one-entry skid buffers can then accept a second request.
        issue_write(5'h00, 32'h1111_0001, 0, 0, 100, 1'b1);
        issue_write(5'h18, 32'h2222_0002, 0, 0,   0, 1'b1);
        issue_read (5'h00, 0, 100, 1'b1);
        issue_read (5'h18, 0,   0, 1'b1);
      end

      V3_MID_RESET_CREDIT_WAIT: begin
        // With depth two, the first response is blocked and the second write
        // occupies the DUT skid buffers.  The third item has been fetched by
        // the Driver but must wait for a credit, so reset must release its
        // finish_item() and return one abort without double-returning credit.
        issue_write(5'h00, 32'hc001_0001, 0, 0, 100, 1'b1);
        issue_write(5'h18, 32'hc002_0002, 0, 0,   0, 1'b1);
        issue_write(5'h10, 32'hc003_0003, 0, 0,   0, 1'b1);
      end

      V3_MID_RESET_COMPLETED_BOUNDARY: begin
        issue_write(5'h00, recovery_data, 0, 0, 0, 1'b0);
        issue_read (5'h00, 0, 0, 1'b0, 1'b1, recovery_data);
      end

      V3_MID_RESET_RECOVERY: begin
        issue_write(5'h00, recovery_data, 0, 0, 0, 1'b0);
        issue_read (5'h00, 0, 0, 1'b0, 1'b1, recovery_data);
      end

      default:
        `uvm_fatal("V3_RESET_BAD_SCENARIO", "unknown mid-reset scenario")
    endcase

    wait (response_count >= requests.size());
    repeat (4) @(vif.mon_cb);

    if (response_count != requests.size())
      `uvm_error("V3_RESET_RESPONSE_COUNT",
        $sformatf("%s received %0d responses for %0d requests",
                  scenario_name(), response_count, requests.size()))
    foreach (response_seen[i]) begin
      if (!response_seen[i])
        `uvm_error("V3_RESET_RESPONSE_MISSING",
          $sformatf("%s missing response index=%0d tr_id=%0d",
                    scenario_name(), i, requests[i].get_transaction_id()))
    end

    `uvm_info("V3_RESET_SCENARIO_DONE",
      $sformatf("scenario=%s requests=%0d responses=%0d",
                scenario_name(), requests.size(), response_count), UVM_NONE)
  endtask
endclass
