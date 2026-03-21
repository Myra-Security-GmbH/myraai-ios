## False Positive Rate Report

_Generated: 2026-03-21 17:10 UTC_

| Detector | Config | Corpus | Total | FP count | FP rate | Top trigger |
|---|---|---|---|---|---|---|
| regex | pii_basic | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | hipaa_structured | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | gdpr_structured | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | pci_pan | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | credentials | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | all_sets | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | phone_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | ssn_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | dob_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | ip_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | routing_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | email_only | or_bench_hard | 1319 | 0 | 0.0% | — |
| regex | pii_basic | xstest_safe | 250 | 0 | 0.0% | — |
| regex | hipaa_structured | xstest_safe | 250 | 0 | 0.0% | — |
| regex | gdpr_structured | xstest_safe | 250 | 0 | 0.0% | — |
| regex | pci_pan | xstest_safe | 250 | 0 | 0.0% | — |
| regex | credentials | xstest_safe | 250 | 0 | 0.0% | — |
| regex | all_sets | xstest_safe | 250 | 0 | 0.0% | — |
| regex | phone_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | ssn_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | dob_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | ip_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | routing_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | email_only | xstest_safe | 250 | 0 | 0.0% | — |
| regex | pii_basic | dolly_sample | 2000 | 2 | 0.1% | phone (2) |
| regex | hipaa_structured | dolly_sample | 2000 | 2 | 0.1% | phone (2) |
| regex | gdpr_structured | dolly_sample | 2000 | 2 | 0.1% | phone (2) |
| regex | pci_pan | dolly_sample | 2000 | 1 | 0.1% | card_expiry (1) |
| regex | credentials | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | all_sets | dolly_sample | 2000 | 2 | 0.1% | phone (2) |
| regex | phone_only | dolly_sample | 2000 | 2 | 0.1% | phone (2) |
| regex | ssn_only | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | dob_only | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | ip_only | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | routing_only | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | email_only | dolly_sample | 2000 | 0 | 0.0% | — |
| regex | pii_basic | handcrafted | 200 | 75 | 37.5% | phone (52) |
| regex | hipaa_structured | handcrafted | 200 | 101 | 50.5% | phone (35) |
| regex | gdpr_structured | handcrafted | 200 | 94 | 47.0% | phone (52) |
| regex | pci_pan | handcrafted | 200 | 17 | 8.5% | routing_number (10) |
| regex | credentials | handcrafted | 200 | 0 | 0.0% | — |
| regex | all_sets | handcrafted | 200 | 101 | 50.5% | phone (52) |
| regex | phone_only | handcrafted | 200 | 52 | 26.0% | phone (52) |
| regex | ssn_only | handcrafted | 200 | 23 | 11.5% | ssn (23) |
| regex | dob_only | handcrafted | 200 | 0 | 0.0% | — |
| regex | ip_only | handcrafted | 200 | 26 | 13.0% | ip_address (26) |
| regex | routing_only | handcrafted | 200 | 10 | 5.0% | routing_number (10) |
| regex | email_only | handcrafted | 200 | 16 | 8.0% | email (16) |
| keyword | violence_block | or_bench_hard | 1319 | 1 | 0.1% | terrorist (1) |
| keyword | violence_block | xstest_safe | 250 | 1 | 0.4% | stab (1) |
| keyword | violence_block | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | violence_block | handcrafted | 200 | 0 | 0.0% | — |
| keyword | hacking_block | or_bench_hard | 1319 | 0 | 0.0% | — |
| keyword | hacking_block | xstest_safe | 250 | 0 | 0.0% | — |
| keyword | hacking_block | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | hacking_block | handcrafted | 200 | 0 | 0.0% | — |
| keyword | drugs_block | or_bench_hard | 1319 | 0 | 0.0% | — |
| keyword | drugs_block | xstest_safe | 250 | 1 | 0.4% | cocaine (1) |
| keyword | drugs_block | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | drugs_block | handcrafted | 200 | 0 | 0.0% | — |
| keyword | restricted_block | or_bench_hard | 1319 | 0 | 0.0% | — |
| keyword | restricted_block | xstest_safe | 250 | 0 | 0.0% | — |
| keyword | restricted_block | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | restricted_block | handcrafted | 200 | 0 | 0.0% | — |
| keyword | violence_flag | or_bench_hard | 1319 | 36 | 2.7% | bomb (21) |
| keyword | violence_flag | xstest_safe | 250 | 15 | 6.0% | kill (6) |
| keyword | violence_flag | dolly_sample | 2000 | 5 | 0.2% | attack (2) |
| keyword | violence_flag | handcrafted | 200 | 11 | 5.5% | kill (6) |
| keyword | hacking_flag | or_bench_hard | 1319 | 71 | 5.4% | malware (23) |
| keyword | hacking_flag | xstest_safe | 250 | 0 | 0.0% | — |
| keyword | hacking_flag | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | hacking_flag | handcrafted | 200 | 4 | 2.0% | hack (2) |
| keyword | drugs_flag | or_bench_hard | 1319 | 3 | 0.2% | methamphetamine (3) |
| keyword | drugs_flag | xstest_safe | 250 | 0 | 0.0% | — |
| keyword | drugs_flag | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | drugs_flag | handcrafted | 200 | 0 | 0.0% | — |
| keyword | restricted_flag | or_bench_hard | 1319 | 39 | 3.0% | restricted (33) |
| keyword | restricted_flag | xstest_safe | 250 | 0 | 0.0% | — |
| keyword | restricted_flag | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | restricted_flag | handcrafted | 200 | 0 | 0.0% | — |
| keyword | self_harm_flag | or_bench_hard | 1319 | 22 | 1.7% | self-harm (18) |
| keyword | self_harm_flag | xstest_safe | 250 | 1 | 0.4% | suicide (1) |
| keyword | self_harm_flag | dolly_sample | 2000 | 0 | 0.0% | — |
| keyword | self_harm_flag | handcrafted | 200 | 0 | 0.0% | — |