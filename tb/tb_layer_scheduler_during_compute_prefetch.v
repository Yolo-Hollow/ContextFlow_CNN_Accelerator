`timescale 1ns / 1ps

`define TB_DURING_COMPUTE_PREFETCH 1
`define TB_LAYER_SCHEDULER_PASS_PREFETCH_MODULE tb_layer_scheduler_during_compute_prefetch
`include "tb/tb_layer_scheduler_pass_prefetch.v"
