`timescale 1ns/1ps
`default_nettype none

module axi4l_bad_slave_checker(axi4l_bad_slave_if vif);
  localparam int F_EARLY_B       = 0;
  localparam int F_EARLY_R       = 1;
  localparam int F_R_STABILITY   = 2;
  localparam int F_B_STABILITY   = 3;
  localparam int F_REQ_STABILITY = 4;
  localparam int F_STALE_RESET   = 5;
  localparam int F_DUPLICATE     = 6;
  localparam int F_MISSING       = 7;

  int unsigned aw_credit, w_credit, ar_credit;
  bit saw_b_response, saw_r_response;
  bit stale_write_credit, stale_read_credit;
  bit prior_aw_stall, prior_w_stall, prior_b_stall, prior_r_stall;
  logic [7:0] prior_aw_payload;
  logic [35:0] prior_w_payload;
  logic [1:0] prior_b_payload;
  logic [33:0] prior_r_payload;

  task automatic flag_fault(int index);
    vif.detected_faults[index] <= 1'b1;
  endtask

  always @(posedge vif.ACLK) begin
    if (vif.clear_faults) begin
      vif.detected_faults <= '0;
      aw_credit <= 0;
      w_credit <= 0;
      ar_credit <= 0;
      saw_b_response <= 1'b0;
      saw_r_response <= 1'b0;
      stale_write_credit <= 1'b0;
      stale_read_credit <= 1'b0;
      prior_aw_stall <= 1'b0;
      prior_w_stall <= 1'b0;
      prior_b_stall <= 1'b0;
      prior_r_stall <= 1'b0;
    end else if (!vif.ARESETN) begin
      stale_write_credit <= stale_write_credit ||
                            ((aw_credit != 0) && (w_credit != 0));
      stale_read_credit <= stale_read_credit || (ar_credit != 0);
      aw_credit <= 0;
      w_credit <= 0;
      ar_credit <= 0;
      prior_aw_stall <= 1'b0;
      prior_w_stall <= 1'b0;
      prior_b_stall <= 1'b0;
      prior_r_stall <= 1'b0;
    end else begin
      if (prior_aw_stall &&
          (!vif.AWVALID || {vif.AWADDR, vif.AWPROT} != prior_aw_payload))
        flag_fault(F_REQ_STABILITY);
      if (prior_w_stall &&
          (!vif.WVALID || {vif.WDATA, vif.WSTRB} != prior_w_payload))
        flag_fault(F_REQ_STABILITY);
      if (prior_b_stall &&
          (!vif.BVALID || vif.BRESP != prior_b_payload))
        flag_fault(F_B_STABILITY);
      if (prior_r_stall &&
          (!vif.RVALID || {vif.RDATA, vif.RRESP} != prior_r_payload))
        flag_fault(F_R_STABILITY);

      prior_aw_stall <= vif.AWVALID && !vif.AWREADY;
      prior_w_stall <= vif.WVALID && !vif.WREADY;
      prior_b_stall <= vif.BVALID && !vif.BREADY;
      prior_r_stall <= vif.RVALID && !vif.RREADY;
      prior_aw_payload <= {vif.AWADDR, vif.AWPROT};
      prior_w_payload <= {vif.WDATA, vif.WSTRB};
      prior_b_payload <= vif.BRESP;
      prior_r_payload <= {vif.RDATA, vif.RRESP};

      if (vif.AWVALID && vif.AWREADY) aw_credit <= aw_credit + 1;
      if (vif.WVALID && vif.WREADY) w_credit <= w_credit + 1;
      if (vif.ARVALID && vif.ARREADY) ar_credit <= ar_credit + 1;

      if (vif.BVALID && (aw_credit == 0 || w_credit == 0)) begin
        if (stale_write_credit)
          flag_fault(F_STALE_RESET);
        else if (saw_b_response)
          flag_fault(F_DUPLICATE);
        else
          flag_fault(F_EARLY_B);
      end
      if (vif.RVALID && (ar_credit == 0)) begin
        if (stale_read_credit)
          flag_fault(F_STALE_RESET);
        else if (saw_r_response)
          flag_fault(F_DUPLICATE);
        else
          flag_fault(F_EARLY_R);
      end

      if (vif.BVALID && vif.BREADY && aw_credit != 0 && w_credit != 0) begin
        aw_credit <= aw_credit - 1;
        w_credit <= w_credit - 1;
        saw_b_response <= 1'b1;
      end
      if (vif.RVALID && vif.RREADY && ar_credit != 0) begin
        ar_credit <= ar_credit - 1;
        saw_r_response <= 1'b1;
      end

      if (vif.audit_pending &&
          (aw_credit != 0 || w_credit != 0 || ar_credit != 0))
        flag_fault(F_MISSING);
    end
  end

  initial begin
    vif.detected_faults = '0;
    aw_credit = 0;
    w_credit = 0;
    ar_credit = 0;
    saw_b_response = 1'b0;
    saw_r_response = 1'b0;
    stale_write_credit = 1'b0;
    stale_read_credit = 1'b0;
    prior_aw_stall = 1'b0;
    prior_w_stall = 1'b0;
    prior_b_stall = 1'b0;
    prior_r_stall = 1'b0;
  end
endmodule

`default_nettype wire
