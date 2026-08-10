# CX-q9sa measured rm_rf guard offenders

This is the pre-cleanup enumeration captured from the restored guard's first full blast-radius run on 2026-08-10. The brief's 41 was a prior, not a target. The measured result is **58 guard firings**: commonplace process 0, commonplace trust 0, commonplace_web 20, commonplace_mcp 21, commonplace_cli 17, commonplace_bots 0, and yelixer 0.

Every measured hit is an ancestor-delete shape: the deletion path contains the captured path. There were no equal-path or child-delete hits in this enumeration. None points at the live workspace store; every captured path is beneath a test-created `/tmp/cp_*` scratch directory.

| # | suite | test file and line | deletion path | captured path | containment |
|---:|---|---|---|---|---|
| 1 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:147` | `/tmp/cp_bd_mcp_test_525914938` | `/tmp/cp_bd_mcp_test_525914938/commits` | deletion contains captured |
| 2 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:177` | `/tmp/cp_bd_mcp_test_187412659` | `/tmp/cp_bd_mcp_test_187412659/commits` | deletion contains captured |
| 3 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:90` | `/tmp/cp_bd_mcp_test_282209192` | `/tmp/cp_bd_mcp_test_282209192/commits` | deletion contains captured |
| 4 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:121` | `/tmp/cp_bd_mcp_test_590326452` | `/tmp/cp_bd_mcp_test_590326452/commits` | deletion contains captured |
| 5 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:63` | `/tmp/cp_bd_mcp_test_350080760` | `/tmp/cp_bd_mcp_test_350080760/commits` | deletion contains captured |
| 6 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:56` | `/tmp/cp_bd_mcp_test_498075672` | `/tmp/cp_bd_mcp_test_498075672/commits` | deletion contains captured |
| 7 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:182` | `/tmp/cp_bd_mcp_test_122730297` | `/tmp/cp_bd_mcp_test_122730297/commits` | deletion contains captured |
| 8 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_tools_test.exs:99` | `/tmp/cp_bd_mcp_test_841748353` | `/tmp/cp_bd_mcp_test_841748353/commits` | deletion contains captured |
| 9 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:172` | `/tmp/cp_bd_write_mcp_test_982065083` | `/tmp/cp_bd_write_mcp_test_982065083/commits` | deletion contains captured |
| 10 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:180` | `/tmp/cp_bd_write_mcp_test_331778950` | `/tmp/cp_bd_write_mcp_test_331778950/commits` | deletion contains captured |
| 11 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:212` | `/tmp/cp_bd_write_mcp_test_938164616` | `/tmp/cp_bd_write_mcp_test_938164616/commits` | deletion contains captured |
| 12 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:134` | `/tmp/cp_bd_write_mcp_test_981887439` | `/tmp/cp_bd_write_mcp_test_981887439/commits` | deletion contains captured |
| 13 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:246` | `/tmp/cp_bd_write_mcp_test_686291895` | `/tmp/cp_bd_write_mcp_test_686291895/commits` | deletion contains captured |
| 14 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:223` | `/tmp/cp_bd_write_mcp_test_48099791` | `/tmp/cp_bd_write_mcp_test_48099791/commits` | deletion contains captured |
| 15 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:158` | `/tmp/cp_bd_write_mcp_test_437157136` | `/tmp/cp_bd_write_mcp_test_437157136/commits` | deletion contains captured |
| 16 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:113` | `/tmp/cp_bd_write_mcp_test_222118051` | `/tmp/cp_bd_write_mcp_test_222118051/commits` | deletion contains captured |
| 17 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:96` | `/tmp/cp_bd_write_mcp_test_165065929` | `/tmp/cp_bd_write_mcp_test_165065929/commits` | deletion contains captured |
| 18 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:192` | `/tmp/cp_bd_write_mcp_test_451225011` | `/tmp/cp_bd_write_mcp_test_451225011/commits` | deletion contains captured |
| 19 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:230` | `/tmp/cp_bd_write_mcp_test_237178694` | `/tmp/cp_bd_write_mcp_test_237178694/commits` | deletion contains captured |
| 20 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:204` | `/tmp/cp_bd_write_mcp_test_298363372` | `/tmp/cp_bd_write_mcp_test_298363372/commits` | deletion contains captured |
| 21 | mcp | `apps/commonplace_mcp/test/commonplace_mcp/tools/bd_write_tools_test.exs:141` | `/tmp/cp_bd_write_mcp_test_512105156` | `/tmp/cp_bd_write_mcp_test_512105156/commits` | deletion contains captured |
| 22 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:83` | `/tmp/cp_outline_live_82965730` | `/tmp/cp_outline_live_82965730/commits` | deletion contains captured |
| 23 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:123` | `/tmp/cp_outline_live_46879164` | `/tmp/cp_outline_live_46879164/commits` | deletion contains captured |
| 24 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:88` | `/tmp/cp_outline_live_882636271` | `/tmp/cp_outline_live_882636271/commits` | deletion contains captured |
| 25 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:112` | `/tmp/cp_outline_live_59057586` | `/tmp/cp_outline_live_59057586/commits` | deletion contains captured |
| 26 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:74` | `/tmp/cp_outline_live_609750697` | `/tmp/cp_outline_live_609750697/commits` | deletion contains captured |
| 27 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:172` | `/tmp/cp_outline_live_10878621` | `/tmp/cp_outline_live_10878621/commits` | deletion contains captured |
| 28 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:99` | `/tmp/cp_outline_live_284819988` | `/tmp/cp_outline_live_284819988/commits` | deletion contains captured |
| 29 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:212` | `/tmp/cp_outline_live_732805088` | `/tmp/cp_outline_live_732805088/commits` | deletion contains captured |
| 30 | web | `apps/commonplace_web/test/commonplace_web_web/live/outline_live_test.exs:149` | `/tmp/cp_outline_live_7429160` | `/tmp/cp_outline_live_7429160/commits` | deletion contains captured |
| 31 | web | `apps/commonplace_web/test/commonplace_web_web/federation_round_trip_test.exs:103` | `/tmp/cp_fed_rt_934179538` | `/tmp/cp_fed_rt_934179538/commits` | deletion contains captured |
| 32 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:119` | `/tmp/cp_fed_ctrl_215185013` | `/tmp/cp_fed_ctrl_215185013/commits` | deletion contains captured |
| 33 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:168` | `/tmp/cp_fed_ctrl_921739438` | `/tmp/cp_fed_ctrl_921739438/commits` | deletion contains captured |
| 34 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:124` | `/tmp/cp_fed_ctrl_649770822` | `/tmp/cp_fed_ctrl_649770822/commits` | deletion contains captured |
| 35 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:219` | `/tmp/cp_fed_ctrl_557820233` | `/tmp/cp_fed_ctrl_557820233/commits` | deletion contains captured |
| 36 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:148` | `/tmp/cp_fed_ctrl_494562676` | `/tmp/cp_fed_ctrl_494562676/commits` | deletion contains captured |
| 37 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:115` | `/tmp/cp_fed_ctrl_515422759` | `/tmp/cp_fed_ctrl_515422759/commits` | deletion contains captured |
| 38 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:199` | `/tmp/cp_fed_ctrl_676234988` | `/tmp/cp_fed_ctrl_676234988/commits` | deletion contains captured |
| 39 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:131` | `/tmp/cp_fed_ctrl_160803887` | `/tmp/cp_fed_ctrl_160803887/commits` | deletion contains captured |
| 40 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:212` | `/tmp/cp_fed_ctrl_89106584` | `/tmp/cp_fed_ctrl_89106584/commits` | deletion contains captured |
| 41 | web | `apps/commonplace_web/test/commonplace_web_web/controllers/federation_controller_test.exs:184` | `/tmp/cp_fed_ctrl_52452534` | `/tmp/cp_fed_ctrl_52452534/commits` | deletion contains captured |
| 42 | cli | `apps/commonplace_cli/test/commonplace/cli_checkout_test.exs:116` | `/tmp/cp_checkout_ws_666859` | `/tmp/cp_checkout_ws_666859/commits` | deletion contains captured |
| 43 | cli | `apps/commonplace_cli/test/commonplace/cli_checkout_test.exs:94` | `/tmp/cp_checkout_ws_411596` | `/tmp/cp_checkout_ws_411596/commits` | deletion contains captured |
| 44 | cli | `apps/commonplace_cli/test/commonplace/cli_checkout_test.exs:88` | `/tmp/cp_checkout_ws_249063` | `/tmp/cp_checkout_ws_249063/commits` | deletion contains captured |
| 45 | cli | `apps/commonplace_cli/test/commonplace/cli_checkout_test.exs:79` | `/tmp/cp_checkout_ws_337111` | `/tmp/cp_checkout_ws_337111/commits` | deletion contains captured |
| 46 | cli | `apps/commonplace_cli/test/commonplace/cli_checkout_test.exs:109` | `/tmp/cp_checkout_ws_604854` | `/tmp/cp_checkout_ws_604854/commits` | deletion contains captured |
| 47 | cli | `apps/commonplace_cli/test/commonplace/cli_sync_test.exs:118` | `/tmp/cp_sync_ws_230684` | `/tmp/cp_sync_ws_230684/commits` | deletion contains captured |
| 48 | cli | `apps/commonplace_cli/test/commonplace/cli_sync_test.exs:104` | `/tmp/cp_sync_ws_243094` | `/tmp/cp_sync_ws_243094/commits` | deletion contains captured |
| 49 | cli | `apps/commonplace_cli/test/commonplace/cli_sync_test.exs:36` | `/tmp/cp_sync_ws_967015` | `/tmp/cp_sync_ws_967015/commits` | deletion contains captured |
| 50 | cli | `apps/commonplace_cli/test/commonplace/cli_sync_test.exs:132` | `/tmp/cp_sync_ws_249428` | `/tmp/cp_sync_ws_249428/commits` | deletion contains captured |
| 51 | cli | `apps/commonplace_cli/test/commonplace/cli_roundtrip_test.exs:73` | `/tmp/cp_rt_ws_513367` | `/tmp/cp_rt_ws_513367/commits` | deletion contains captured |
| 52 | cli | `apps/commonplace_cli/test/commonplace/cli_roundtrip_test.exs:32` | `/tmp/cp_rt_ws_528357` | `/tmp/cp_rt_ws_528357/commits` | deletion contains captured |
| 53 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:190` | `/tmp/cp_test_ws_810126` | `/tmp/cp_test_ws_810126/commits` | deletion contains captured |
| 54 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:165` | `/tmp/cp_test_ws_159772` | `/tmp/cp_test_ws_159772/commits` | deletion contains captured |
| 55 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:117` | `/tmp/cp_test_ws_283123` | `/tmp/cp_test_ws_283123/commits` | deletion contains captured |
| 56 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:51` | `/tmp/cp_test_ws_888803` | `/tmp/cp_test_ws_888803/commits` | deletion contains captured |
| 57 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:32` | `/tmp/cp_test_ws_112250` | `/tmp/cp_test_ws_112250/commits` | deletion contains captured |
| 58 | cli | `apps/commonplace_cli/test/commonplace/cli_integration_test.exs:139` | `/tmp/cp_test_ws_505858` | `/tmp/cp_test_ws_505858/commits` | deletion contains captured |
