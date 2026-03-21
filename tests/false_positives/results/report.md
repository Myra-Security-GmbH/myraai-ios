## False Positive Rate Report

_Generated: 2026-03-21 18:02 UTC_

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
| presidio | threshold=0.5_entities=all_entities | or_bench_hard | 500 | 6 | 1.2% | PERSON (2) |
| presidio | threshold=0.5_entities=person_email | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.5_entities=pii_core | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.5_entities=pii_focused | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.6_entities=all_entities | or_bench_hard | 500 | 6 | 1.2% | PERSON (2) |
| presidio | threshold=0.6_entities=person_email | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.6_entities=pii_core | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.6_entities=pii_focused | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.7_entities=all_entities | or_bench_hard | 500 | 6 | 1.2% | PERSON (2) |
| presidio | threshold=0.7_entities=person_email | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.7_entities=pii_core | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.7_entities=pii_focused | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.8_entities=all_entities | or_bench_hard | 500 | 6 | 1.2% | PERSON (2) |
| presidio | threshold=0.8_entities=person_email | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.8_entities=pii_core | or_bench_hard | 500 | 2 | 0.4% | PERSON (2) |
| presidio | threshold=0.8_entities=pii_focused | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=all_entities | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=person_email | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_core | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_focused | or_bench_hard | 500 | 0 | 0.0% | — |
| presidio | threshold=0.5_entities=all_entities | xstest_safe | 250 | 76 | 30.4% | PERSON (52) |
| presidio | threshold=0.5_entities=person_email | xstest_safe | 250 | 49 | 19.6% | PERSON (52) |
| presidio | threshold=0.5_entities=pii_core | xstest_safe | 250 | 62 | 24.8% | PERSON (52) |
| presidio | threshold=0.5_entities=pii_focused | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.6_entities=all_entities | xstest_safe | 250 | 76 | 30.4% | PERSON (52) |
| presidio | threshold=0.6_entities=person_email | xstest_safe | 250 | 49 | 19.6% | PERSON (52) |
| presidio | threshold=0.6_entities=pii_core | xstest_safe | 250 | 62 | 24.8% | PERSON (52) |
| presidio | threshold=0.6_entities=pii_focused | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.7_entities=all_entities | xstest_safe | 250 | 76 | 30.4% | PERSON (52) |
| presidio | threshold=0.7_entities=person_email | xstest_safe | 250 | 49 | 19.6% | PERSON (52) |
| presidio | threshold=0.7_entities=pii_core | xstest_safe | 250 | 62 | 24.8% | PERSON (52) |
| presidio | threshold=0.7_entities=pii_focused | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.8_entities=all_entities | xstest_safe | 250 | 76 | 30.4% | PERSON (52) |
| presidio | threshold=0.8_entities=person_email | xstest_safe | 250 | 49 | 19.6% | PERSON (52) |
| presidio | threshold=0.8_entities=pii_core | xstest_safe | 250 | 62 | 24.8% | PERSON (52) |
| presidio | threshold=0.8_entities=pii_focused | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=all_entities | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=person_email | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_core | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_focused | xstest_safe | 250 | 0 | 0.0% | — |
| presidio | threshold=0.5_entities=all_entities | dolly_sample | 500 | 200 | 40.0% | LOCATION (253) |
| presidio | threshold=0.5_entities=person_email | dolly_sample | 500 | 88 | 17.6% | PERSON (130) |
| presidio | threshold=0.5_entities=pii_core | dolly_sample | 500 | 164 | 32.8% | LOCATION (253) |
| presidio | threshold=0.5_entities=pii_focused | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.6_entities=all_entities | dolly_sample | 500 | 200 | 40.0% | LOCATION (253) |
| presidio | threshold=0.6_entities=person_email | dolly_sample | 500 | 88 | 17.6% | PERSON (130) |
| presidio | threshold=0.6_entities=pii_core | dolly_sample | 500 | 164 | 32.8% | LOCATION (253) |
| presidio | threshold=0.6_entities=pii_focused | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.7_entities=all_entities | dolly_sample | 500 | 200 | 40.0% | LOCATION (253) |
| presidio | threshold=0.7_entities=person_email | dolly_sample | 500 | 88 | 17.6% | PERSON (130) |
| presidio | threshold=0.7_entities=pii_core | dolly_sample | 500 | 164 | 32.8% | LOCATION (253) |
| presidio | threshold=0.7_entities=pii_focused | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.8_entities=all_entities | dolly_sample | 500 | 200 | 40.0% | LOCATION (253) |
| presidio | threshold=0.8_entities=person_email | dolly_sample | 500 | 88 | 17.6% | PERSON (130) |
| presidio | threshold=0.8_entities=pii_core | dolly_sample | 500 | 164 | 32.8% | LOCATION (253) |
| presidio | threshold=0.8_entities=pii_focused | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=all_entities | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=person_email | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_core | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.9_entities=pii_focused | dolly_sample | 500 | 0 | 0.0% | — |
| presidio | threshold=0.5_entities=all_entities | handcrafted | 200 | 104 | 52.0% | DATE_TIME (44) |
| presidio | threshold=0.5_entities=person_email | handcrafted | 200 | 23 | 11.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.5_entities=pii_core | handcrafted | 200 | 39 | 19.5% | LOCATION (18) |
| presidio | threshold=0.5_entities=pii_focused | handcrafted | 200 | 20 | 10.0% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.6_entities=all_entities | handcrafted | 200 | 102 | 51.0% | DATE_TIME (44) |
| presidio | threshold=0.6_entities=person_email | handcrafted | 200 | 23 | 11.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.6_entities=pii_core | handcrafted | 200 | 39 | 19.5% | LOCATION (18) |
| presidio | threshold=0.6_entities=pii_focused | handcrafted | 200 | 20 | 10.0% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.7_entities=all_entities | handcrafted | 200 | 71 | 35.5% | DATE_TIME (28) |
| presidio | threshold=0.7_entities=person_email | handcrafted | 200 | 23 | 11.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.7_entities=pii_core | handcrafted | 200 | 39 | 19.5% | LOCATION (18) |
| presidio | threshold=0.7_entities=pii_focused | handcrafted | 200 | 20 | 10.0% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.8_entities=all_entities | handcrafted | 200 | 71 | 35.5% | DATE_TIME (28) |
| presidio | threshold=0.8_entities=person_email | handcrafted | 200 | 23 | 11.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.8_entities=pii_core | handcrafted | 200 | 39 | 19.5% | LOCATION (18) |
| presidio | threshold=0.8_entities=pii_focused | handcrafted | 200 | 20 | 10.0% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.9_entities=all_entities | handcrafted | 200 | 22 | 11.0% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.9_entities=person_email | handcrafted | 200 | 15 | 7.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.9_entities=pii_core | handcrafted | 200 | 15 | 7.5% | EMAIL_ADDRESS (15) |
| presidio | threshold=0.9_entities=pii_focused | handcrafted | 200 | 20 | 10.0% | EMAIL_ADDRESS (15) |
| llm_guard | all_categories | or_bench_hard | 200 | 24 | 12.0% | S2 (13) |
| llm_guard | crime_nvc | or_bench_hard | 200 | 13 | 6.5% | S2 (13) |
| llm_guard | hate_only | or_bench_hard | 200 | 5 | 2.5% | S10 (5) |
| llm_guard | violent_crimes | or_bench_hard | 200 | 0 | 0.0% | — |
| llm_guard | cbrn_weapons | or_bench_hard | 200 | 2 | 1.0% | S9 (2) |
| llm_guard | csam | or_bench_hard | 200 | 0 | 0.0% | — |
| llm_guard | suicide_self_harm | or_bench_hard | 200 | 0 | 0.0% | — |
| llm_guard | recommended_block | or_bench_hard | 200 | 2 | 1.0% | S9 (2) |
| llm_guard | violence_hate | or_bench_hard | 200 | 0 | 0.0% | — |
| llm_guard | weapons_csam | or_bench_hard | 200 | 15 | 7.5% | S2 (13) |
| llm_guard | crime_privacy | or_bench_hard | 200 | 3 | 1.5% | S5 (2) |
| llm_guard | narrow_block | or_bench_hard | 200 | 15 | 7.5% | S2 (13) |
| llm_guard | all_categories | xstest_safe | 200 | 2 | 1.0% | S1 (2) |
| llm_guard | crime_nvc | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | hate_only | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | violent_crimes | xstest_safe | 200 | 2 | 1.0% | S1 (2) |
| llm_guard | cbrn_weapons | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | csam | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | suicide_self_harm | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | recommended_block | xstest_safe | 200 | 2 | 1.0% | S1 (2) |
| llm_guard | violence_hate | xstest_safe | 200 | 2 | 1.0% | S1 (2) |
| llm_guard | weapons_csam | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | crime_privacy | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | narrow_block | xstest_safe | 200 | 0 | 0.0% | — |
| llm_guard | all_categories | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | crime_nvc | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | hate_only | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | violent_crimes | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | cbrn_weapons | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | csam | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | suicide_self_harm | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | recommended_block | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | violence_hate | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | weapons_csam | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | crime_privacy | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | narrow_block | dolly_sample | 200 | 0 | 0.0% | — |
| llm_guard | all_categories | handcrafted | 200 | 3 | 1.5% | S7 (3) |
| llm_guard | crime_nvc | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | hate_only | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | violent_crimes | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | cbrn_weapons | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | csam | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | suicide_self_harm | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | recommended_block | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | violence_hate | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | weapons_csam | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | crime_privacy | handcrafted | 200 | 0 | 0.0% | — |
| llm_guard | narrow_block | handcrafted | 200 | 0 | 0.0% | — |