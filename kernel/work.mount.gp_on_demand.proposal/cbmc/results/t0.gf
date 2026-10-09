Reading GOTO program from 't0.goto'
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

__CPROVER__start /* __CPROVER__start */
        // 52 no location
        // Labels: __CPROVER_HIDE
        SKIP
        // 53 file <built-in-additions> line 24
        CALL __CPROVER_initialize()
        // 54 file mntput_harness.c line 1236
        CALL return' := main()
        // 55 file mntput_harness.c line 1236
        OUTPUT address_of("return'"[0])
        // 56 no location
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

__CPROVER_initialize /* __CPROVER_initialize */
        // 916 no location
        // Labels: __CPROVER_HIDE
        SKIP
        // 917 file <built-in-additions> line 8
        ASSIGN __CPROVER_dead_object := NULL
        // 918 file <built-in-additions> line 7
        ASSIGN __CPROVER_deallocated := NULL
        // 919 file <built-in-additions> line 12
        ASSIGN __CPROVER_max_malloc_size := 36028797018963968
        // 920 file <built-in-additions> line 9
        ASSIGN __CPROVER_memory_leak := NULL
        // 921 file <built-in-additions> line 16
        ASSIGN __CPROVER_rounding_mode := 0
        // 922 file mntput_harness.c line 234
        ASSIGN dentries := { { 0 } }
        // 923 file mntput_harness.c line 484
        ASSIGN event := 0
        // 924 file mntput_harness.c line 256
        ASSIGN ghost_caller_put := 0
        // 925 file mntput_harness.c line 250
        ASSIGN ghost_cleaned := { 0 }
        // 926 file mntput_harness.c line 251
        ASSIGN ghost_cleaner := { 0 }
        // 927 file mntput_harness.c line 254
        ASSIGN ghost_fast_final := { 0 }
        // 928 file mntput_harness.c line 252
        ASSIGN ghost_freed := { 0 }
        // 929 file mntput_harness.c line 255
        ASSIGN ghost_gps := 0
        // 930 file mntput_harness.c line 249
        ASSIGN ghost_hashed := { 0 }
        // 931 file mntput_harness.c line 247
        ASSIGN ghost_refs := { { 0 }, { 0 }, { 0 } }
        // 932 file mntput_harness.c line 253
        ASSIGN ghost_sb_torn := { 0 }
        // 933 file mntput_harness.c line 248
        ASSIGN ghost_transient := { 0, 0, 0 }
        // 934 file mntput_harness.c line 257
        ASSIGN ghost_umounted := { 0 }
        // 935 file mntput_harness.c line 396
        ASSIGN in_rcu := { 0, 0, 0 }
        // 936 file mntput_harness.c line 336
        ASSIGN mount_lock := { 0, 0, 0 }
        // 937 file mntput_harness.c line 232
        ASSIGN mounts := { { 0, 0, NULL, { NULL, NULL, 0, 0 }, { NULL }, { { 0, 0, 0 }, { 0, 0, 0 } }, 0, 0, 0, 0, NULL } }
        // 938 file mntput_harness.c line 233
        ASSIGN sbs := { { NULL, 0, 0 } }
        // 939 file mntput_harness.c line 442
        ASSIGN task_work_pending := { 0 }
        // 940 file mntput_harness.c line 437
        ASSIGN tasks := { { 0 }, { 0 }, { 0 } }
        // 941 file mntput_harness.c line 1175
        ASSIGN thread_done := { 0, 0, 0 }
        // 942 file mntput_harness.c line 114
        ASSIGN tid := 0
        // 943 file mntput_harness.c line 485
        ASSIGN unmounted := { 0, { 0 }, { 0 } }
        // 944 no location
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

__cleanup_mnt /* __cleanup_mnt */
        // 657 file mntput_harness.c line 675 function __cleanup_mnt
        CALL cleanup_mnt(cast(cast(__cleanup_mnt::head, signedbv[8]*) - cast(40, signedbv[64]), struct tag-mount*))
        // 658 file mntput_harness.c line 676 function __cleanup_mnt
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

__legitimize_mnt /* __legitimize_mnt */
        // 492 file mntput_harness.c line 600 function __legitimize_mnt
        DECL __legitimize_mnt::1::mnt : struct tag-mount*
        // 493 file mntput_harness.c line 601 function __legitimize_mnt
        DECL __legitimize_mnt::$tmp::return_value_read_seqretry : unsignedbv[32]
        // 494 file mntput_harness.c line 601 function __legitimize_mnt
        CALL __legitimize_mnt::$tmp::return_value_read_seqretry := read_seqretry(address_of(mount_lock), __legitimize_mnt::seq)
        // 495 file mntput_harness.c line 601 function __legitimize_mnt
        IF ¬(__legitimize_mnt::$tmp::return_value_read_seqretry ≠ 0) THEN GOTO 1
        // 496 file mntput_harness.c line 601 function __legitimize_mnt
        DEAD __legitimize_mnt::$tmp::return_value_read_seqretry
        // 497 file mntput_harness.c line 602 function __legitimize_mnt
        SET RETURN VALUE 1
        // 498 file mntput_harness.c line 602 function __legitimize_mnt
        DEAD __legitimize_mnt::1::mnt
        // 499 file mntput_harness.c line 602 function __legitimize_mnt
        GOTO 5
        // 500 file mntput_harness.c line 601 function __legitimize_mnt
     1: DEAD __legitimize_mnt::$tmp::return_value_read_seqretry
        // 501 file mntput_harness.c line 603 function __legitimize_mnt
        IF ¬(__legitimize_mnt::bastard = NULL) THEN GOTO 2
        // 502 file mntput_harness.c line 604 function __legitimize_mnt
        SET RETURN VALUE 0
        // 503 file mntput_harness.c line 604 function __legitimize_mnt
        DEAD __legitimize_mnt::1::mnt
        // 504 file mntput_harness.c line 604 function __legitimize_mnt
        GOTO 5
        // 505 file mntput_harness.c line 604 function __legitimize_mnt
     2: SKIP
        // 506 file mntput_harness.c line 605 function __legitimize_mnt
        CALL __legitimize_mnt::1::mnt := real_mount(__legitimize_mnt::bastard)
        // 507 file mntput_harness.c line 606 function __legitimize_mnt
        CALL mnt_inc_count(__legitimize_mnt::1::mnt)
        // 508 file mntput_harness.c line 608 function __legitimize_mnt
        FENCE WW RR RW WR
        // 509 file mntput_harness.c line 610 function __legitimize_mnt
        DECL __legitimize_mnt::$tmp::return_value_read_seqretry$0 : unsignedbv[32]
        // 510 file mntput_harness.c line 610 function __legitimize_mnt
        CALL __legitimize_mnt::$tmp::return_value_read_seqretry$0 := read_seqretry(address_of(mount_lock), __legitimize_mnt::seq)
        // 511 file mntput_harness.c line 610 function __legitimize_mnt
        IF __legitimize_mnt::$tmp::return_value_read_seqretry$0 ≠ 0 THEN GOTO 3
        // 512 file mntput_harness.c line 610 function __legitimize_mnt
        DEAD __legitimize_mnt::$tmp::return_value_read_seqretry$0
        // 513 file mntput_harness.c line 611 function __legitimize_mnt
        SET RETURN VALUE 0
        // 514 file mntput_harness.c line 611 function __legitimize_mnt
        DEAD __legitimize_mnt::1::mnt
        // 515 file mntput_harness.c line 611 function __legitimize_mnt
        GOTO 5
        // 516 file mntput_harness.c line 610 function __legitimize_mnt
     3: DEAD __legitimize_mnt::$tmp::return_value_read_seqretry$0
        // 517 file mntput_harness.c line 612 function __legitimize_mnt
        CALL lock_mount_hash()
        // 518 file mntput_harness.c line 613 function __legitimize_mnt
        DECL __legitimize_mnt::$tmp::return_value_mnt_idx : signedbv[32]
        // 519 file mntput_harness.c line 613 function __legitimize_mnt
        CALL __legitimize_mnt::$tmp::return_value_mnt_idx := mnt_idx(__legitimize_mnt::1::mnt)
        // 520 file mntput_harness.c line 613 function __legitimize_mnt
        ASSERT ¬(ghost_freed[cast(__legitimize_mnt::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 521 file mntput_harness.c line 613 function __legitimize_mnt
        DEAD __legitimize_mnt::$tmp::return_value_mnt_idx
        // 522 file mntput_harness.c line 617 function __legitimize_mnt
        IF ¬(bitand(*__legitimize_mnt::bastard.mnt_flags, bitor(33554432, 16777216)) ≠ 0) THEN GOTO 4
        // 523 file mntput_harness.c line 619 function __legitimize_mnt
        CALL mnt_dec_count(__legitimize_mnt::1::mnt)
        // 524 file mntput_harness.c line 620 function __legitimize_mnt
        CALL unlock_mount_hash()
        // 525 file mntput_harness.c line 621 function __legitimize_mnt
        SET RETURN VALUE 1
        // 526 file mntput_harness.c line 621 function __legitimize_mnt
        DEAD __legitimize_mnt::1::mnt
        // 527 file mntput_harness.c line 621 function __legitimize_mnt
        GOTO 5
        // 528 file mntput_harness.c line 622 function __legitimize_mnt
     4: SKIP
        // 529 file mntput_harness.c line 623 function __legitimize_mnt
        CALL unlock_mount_hash()
        // 530 file mntput_harness.c line 625 function __legitimize_mnt
        SET RETURN VALUE -1
        // 531 file mntput_harness.c line 625 function __legitimize_mnt
        DEAD __legitimize_mnt::1::mnt
        // 532 file mntput_harness.c line 625 function __legitimize_mnt
        GOTO 5
        // 533 file mntput_harness.c line 626 function __legitimize_mnt
     5: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

__synchronize_rcu /* __synchronize_rcu */
        // 758 file mntput_harness.c line 409 function __synchronize_rcu
        DECL __synchronize_rcu::1::t : signedbv[32]
        // 759 file mntput_harness.c line 411 function __synchronize_rcu
        FENCE WW RR RW WR
        // 760 file mntput_harness.c line 412 function __synchronize_rcu
        ASSIGN __synchronize_rcu::1::t := 0
        // 761 file mntput_harness.c line 412 function __synchronize_rcu
     1: IF ¬(__synchronize_rcu::1::t < 3) THEN GOTO 3
        // 762 file mntput_harness.c line 413 function __synchronize_rcu
        IF __synchronize_rcu::1::t = tid THEN GOTO 2
        // 763 file mntput_harness.c line 414 function __synchronize_rcu
        SKIP
        // 764 file mntput_harness.c line 414 function __synchronize_rcu
        SKIP
        // 765 file mntput_harness.c line 415 function __synchronize_rcu
        ATOMIC_BEGIN
        // 766 file mntput_harness.c line 416 function __synchronize_rcu
        ASSUME ¬(in_rcu[cast(__synchronize_rcu::1::t, signedbv[64])] ≠ 0)
        // 767 file mntput_harness.c line 417 function __synchronize_rcu
        ATOMIC_END
        // 768 file mntput_harness.c line 412 function __synchronize_rcu
     2: ASSIGN __synchronize_rcu::1::t := __synchronize_rcu::1::t + 1
        // 769 file mntput_harness.c line 412 function __synchronize_rcu
        GOTO 1
        // 770 file mntput_harness.c line 412 function __synchronize_rcu
     3: SKIP
        // 771 file mntput_harness.c line 419 function __synchronize_rcu
        FENCE WW RR RW WR
        // 772 file mntput_harness.c line 420 function __synchronize_rcu
        DEAD __synchronize_rcu::1::t
        // 773 file mntput_harness.c line 420 function __synchronize_rcu
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

check_mnt /* check_mnt */
        // 790 file mntput_harness.c line 508 function check_mnt
        SET RETURN VALUE cast(*check_mnt::mnt.mnt_ns = 1, signedbv[32])
        // 791 file mntput_harness.c line 508 function check_mnt
        GOTO 1
        // 792 file mntput_harness.c line 509 function check_mnt
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

cleanup_mnt /* cleanup_mnt */
        // 562 file mntput_harness.c line 646 function cleanup_mnt
        DECL cleanup_mnt::1::idx : signedbv[32]
        // 563 file mntput_harness.c line 646 function cleanup_mnt
        DECL cleanup_mnt::$tmp::return_value_mnt_idx : signedbv[32]
        // 564 file mntput_harness.c line 646 function cleanup_mnt
        CALL cleanup_mnt::$tmp::return_value_mnt_idx := mnt_idx(cleanup_mnt::mnt)
        // 565 file mntput_harness.c line 646 function cleanup_mnt
        ASSIGN cleanup_mnt::1::idx := cleanup_mnt::$tmp::return_value_mnt_idx
        // 566 file mntput_harness.c line 646 function cleanup_mnt
        DEAD cleanup_mnt::$tmp::return_value_mnt_idx
        // 567 file mntput_harness.c line 648 function cleanup_mnt
        DECL cleanup_mnt::$tmp::return_value_mnt_idx$0 : signedbv[32]
        // 568 file mntput_harness.c line 648 function cleanup_mnt
        CALL cleanup_mnt::$tmp::return_value_mnt_idx$0 := mnt_idx(cleanup_mnt::mnt)
        // 569 file mntput_harness.c line 648 function cleanup_mnt
        ASSERT ¬(ghost_freed[cast(cleanup_mnt::$tmp::return_value_mnt_idx$0, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 570 file mntput_harness.c line 648 function cleanup_mnt
        DEAD cleanup_mnt::$tmp::return_value_mnt_idx$0
        // 571 file mntput_harness.c line 650 function cleanup_mnt
        ASSERT ¬(ghost_cleaned[cast(cleanup_mnt::1::idx, signedbv[64])] ≠ 0) // CleanupOnce: cleanup_mnt() twice for one mount
        // 572 file mntput_harness.c line 651 function cleanup_mnt
        ASSERT bitand(*cleanup_mnt::mnt.mnt.mnt_flags, 16777216) ≠ 0 // cleanup_mnt() of a mount that is not doomed
        // 573 file mntput_harness.c line 652 function cleanup_mnt
        ASSIGN ghost_cleaned[cast(cleanup_mnt::1::idx, signedbv[64])] := 1
        // 574 file mntput_harness.c line 653 function cleanup_mnt
        ASSIGN ghost_cleaner[cast(cleanup_mnt::1::idx, signedbv[64])] := tid
        // 575 file mntput_harness.c line 662 function cleanup_mnt
        DECL cleanup_mnt::1::1::__c : signedbv[32]
        // 576 file mntput_harness.c line 662 function cleanup_mnt
        DECL cleanup_mnt::$tmp::return_value_mnt_get_writers : signedbv[32]
        // 577 file mntput_harness.c line 662 function cleanup_mnt
        CALL cleanup_mnt::$tmp::return_value_mnt_get_writers := mnt_get_writers(cleanup_mnt::mnt)
        // 578 file mntput_harness.c line 662 function cleanup_mnt
        ASSIGN cleanup_mnt::1::1::__c := cast(¬(¬(cleanup_mnt::$tmp::return_value_mnt_get_writers ≠ 0)), signedbv[32])
        // 579 file mntput_harness.c line 662 function cleanup_mnt
        DEAD cleanup_mnt::$tmp::return_value_mnt_get_writers
        // 580 file mntput_harness.c line 662 function cleanup_mnt
        ASSERT ¬(cleanup_mnt::1::1::__c ≠ 0) // WARN_ON(mnt_get_writers(mnt))
        // 581 file mntput_harness.c line 662 function cleanup_mnt
        EXPRESSION cleanup_mnt::1::1::__c
        // 582 file mntput_harness.c line 662 function cleanup_mnt
        DEAD cleanup_mnt::1::1::__c
        // 583 file mntput_harness.c line 663 function cleanup_mnt
        IF ¬(*cleanup_mnt::mnt.mnt_pins ≠ NULL) THEN GOTO 1
        // 584 file mntput_harness.c line 664 function cleanup_mnt
        CALL mnt_pin_kill(cleanup_mnt::mnt)
        // 585 file mntput_harness.c line 664 function cleanup_mnt
     1: SKIP
        // 586 file mntput_harness.c line 665 function cleanup_mnt
        CALL fsnotify_vfsmount_delete(address_of(*cleanup_mnt::mnt.mnt))
        // 587 file mntput_harness.c line 666 function cleanup_mnt
        CALL dput(*cleanup_mnt::mnt.mnt.mnt_root)
        // 588 file mntput_harness.c line 667 function cleanup_mnt
        CALL deactivate_super(*cleanup_mnt::mnt.mnt.mnt_sb)
        // 589 file mntput_harness.c line 668 function cleanup_mnt
        ASSIGN ghost_sb_torn[cast(cleanup_mnt::1::idx, signedbv[64])] := 1
        // 590 file mntput_harness.c line 669 function cleanup_mnt
        CALL mnt_free_id(cleanup_mnt::mnt)
        // 591 file mntput_harness.c line 670 function cleanup_mnt
     2: CALL __synchronize_rcu()
        // 592 file mntput_harness.c line 670 function cleanup_mnt
        CALL delayed_free_vfsmnt(address_of(*cleanup_mnt::mnt.mnt_rcu))
        // 593 file mntput_harness.c line 670 function cleanup_mnt
        IF 0 ≠ 0 THEN GOTO 2
        // 594 file mntput_harness.c line 670 function cleanup_mnt
        SKIP
        // 595 file mntput_harness.c line 670 function cleanup_mnt
        SKIP
        // 596 file mntput_harness.c line 671 function cleanup_mnt
        DEAD cleanup_mnt::1::idx
        // 597 file mntput_harness.c line 671 function cleanup_mnt
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

deactivate_super /* deactivate_super */
        // 803 file mntput_harness.c line 491 function deactivate_super
        SKIP
        // 804 file mntput_harness.c line 491 function deactivate_super
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

delayed_free_vfsmnt /* delayed_free_vfsmnt */
        // 914 file mntput_harness.c line 594 function delayed_free_vfsmnt
        CALL free_vfsmnt(cast(cast(delayed_free_vfsmnt::head, signedbv[8]*) - cast(40, signedbv[64]), struct tag-mount*))
        // 915 file mntput_harness.c line 595 function delayed_free_vfsmnt
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

do_refcount_check /* do_refcount_check */
        // 662 file mntput_harness.c line 1007 function do_refcount_check
        DECL do_refcount_check::$tmp::return_value_mnt_get_count : signedbv[32]
        // 663 file mntput_harness.c line 1007 function do_refcount_check
        CALL do_refcount_check::$tmp::return_value_mnt_get_count := mnt_get_count(do_refcount_check::mnt)
        // 664 file mntput_harness.c line 1007 function do_refcount_check
        SET RETURN VALUE cast(do_refcount_check::$tmp::return_value_mnt_get_count > do_refcount_check::count, signedbv[32])
        // 665 file mntput_harness.c line 1007 function do_refcount_check
        DEAD do_refcount_check::$tmp::return_value_mnt_get_count
        // 666 file mntput_harness.c line 1007 function do_refcount_check
        GOTO 1
        // 667 file mntput_harness.c line 1008 function do_refcount_check
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

do_umount /* do_umount */
        // 128 file mntput_harness.c line 1047 function do_umount
        DECL do_umount::1::ref : struct tag-mount*
        // 129 file mntput_harness.c line 1047 function do_umount
        ASSIGN do_umount::1::ref := do_umount::mnt
        // 130 file mntput_harness.c line 1048 function do_umount
        DECL do_umount::1::sb : struct tag-super_block*
        // 131 file mntput_harness.c line 1048 function do_umount
        ASSIGN do_umount::1::sb := *do_umount::mnt.mnt.mnt_sb
        // 132 file mntput_harness.c line 1049 function do_umount
        DECL do_umount::1::retval : signedbv[32]
        // 133 file mntput_harness.c line 1051 function do_umount
        CALL do_umount::1::retval := security_sb_umount(address_of(*do_umount::mnt.mnt), do_umount::flags)
        // 134 file mntput_harness.c line 1052 function do_umount
        IF ¬(do_umount::1::retval ≠ 0) THEN GOTO 3
        // 135 file mntput_harness.c line 1053 function do_umount
     1: IF ¬(do_umount::1::ref ≠ NULL) THEN GOTO 2
        // 136 file mntput_harness.c line 1053 function do_umount
        ASSIGN ghost_caller_put := ghost_caller_put + 1
        // 137 file mntput_harness.c line 1053 function do_umount
        CALL mntput_no_expire(do_umount::1::ref)
        // 138 file mntput_harness.c line 1053 function do_umount
     2: SKIP
        // 139 file mntput_harness.c line 1053 function do_umount
        IF 0 ≠ 0 THEN GOTO 1
        // 140 file mntput_harness.c line 1053 function do_umount
        SKIP
        // 141 file mntput_harness.c line 1053 function do_umount
        SKIP
        // 142 file mntput_harness.c line 1054 function do_umount
        SET RETURN VALUE do_umount::1::retval
        // 143 file mntput_harness.c line 1054 function do_umount
        DEAD do_umount::1::retval
        // 144 file mntput_harness.c line 1054 function do_umount
        DEAD do_umount::1::sb
        // 145 file mntput_harness.c line 1054 function do_umount
        DEAD do_umount::1::ref
        // 146 file mntput_harness.c line 1054 function do_umount
        GOTO 16
        // 147 file mntput_harness.c line 1055 function do_umount
     3: SKIP
        // 148 file mntput_harness.c line 1057 function do_umount
        CALL namespace_lock()
        // 149 file mntput_harness.c line 1058 function do_umount
        CALL lock_mount_hash()
        // 150 file mntput_harness.c line 1061 function do_umount
        ASSIGN do_umount::1::retval := -22
        // 151 file mntput_harness.c line 1062 function do_umount
        DECL do_umount::$tmp::return_value_check_mnt : signedbv[32]
        // 152 file mntput_harness.c line 1062 function do_umount
        CALL do_umount::$tmp::return_value_check_mnt := check_mnt(do_umount::mnt)
        // 153 file mntput_harness.c line 1062 function do_umount
        IF do_umount::$tmp::return_value_check_mnt ≠ 0 THEN GOTO 4
        // 154 file mntput_harness.c line 1062 function do_umount
        DEAD do_umount::$tmp::return_value_check_mnt
        // 155 file mntput_harness.c line 1063 function do_umount
        GOTO 13
        // 156 file mntput_harness.c line 1063 function do_umount
        GOTO 5
        // 157 file mntput_harness.c line 1062 function do_umount
     4: DEAD do_umount::$tmp::return_value_check_mnt
        // 158 
     5: SKIP
        // 159 file mntput_harness.c line 1065 function do_umount
        IF bitand(*do_umount::mnt.mnt.mnt_flags, 8388608) ≠ 0 THEN GOTO 13
        // 160 file mntput_harness.c line 1066 function do_umount
        SKIP
        // 161 file mntput_harness.c line 1066 function do_umount
        SKIP
        // 162 file mntput_harness.c line 1068 function do_umount
        DECL do_umount::$tmp::return_value_mnt_has_parent : signedbv[32]
        // 163 file mntput_harness.c line 1068 function do_umount
        CALL do_umount::$tmp::return_value_mnt_has_parent := mnt_has_parent(do_umount::mnt)
        // 164 file mntput_harness.c line 1068 function do_umount
        IF do_umount::$tmp::return_value_mnt_has_parent ≠ 0 THEN GOTO 6
        // 165 file mntput_harness.c line 1068 function do_umount
        DEAD do_umount::$tmp::return_value_mnt_has_parent
        // 166 file mntput_harness.c line 1069 function do_umount
        GOTO 13
        // 167 file mntput_harness.c line 1069 function do_umount
        GOTO 7
        // 168 file mntput_harness.c line 1068 function do_umount
     6: DEAD do_umount::$tmp::return_value_mnt_has_parent
        // 169 
     7: SKIP
        // 170 file mntput_harness.c line 1071 function do_umount
        ASSIGN event := event + 1
        // 171 file mntput_harness.c line 1072 function do_umount
        IF ¬(bitand(do_umount::flags, 2) ≠ 0) THEN GOTO 8
        // 172 file mntput_harness.c line 1073 function do_umount
        CALL umount_tree(do_umount::mnt, cast(2, c_enum tag-umount_tree_flags))
        // 173 file mntput_harness.c line 1074 function do_umount
        ASSIGN do_umount::1::retval := 0
        // 174 file mntput_harness.c line 1075 function do_umount
        GOTO 11
        // 175 file mntput_harness.c line 1076 function do_umount
     8: FENCE WW RR RW WR
        // 176 file mntput_harness.c line 1077 function do_umount
        CALL shrink_submounts(do_umount::mnt)
        // 177 file mntput_harness.c line 1078 function do_umount
        ASSIGN do_umount::1::retval := -16
        // 178 file mntput_harness.c line 1079 function do_umount
        DECL do_umount::$tmp::return_value_propagate_mount_busy : signedbv[32]
        // 179 file mntput_harness.c line 1079 function do_umount
        CALL do_umount::$tmp::return_value_propagate_mount_busy := propagate_mount_busy(do_umount::mnt, 2)
        // 180 file mntput_harness.c line 1079 function do_umount
        IF do_umount::$tmp::return_value_propagate_mount_busy ≠ 0 THEN GOTO 9
        // 181 file mntput_harness.c line 1079 function do_umount
        DEAD do_umount::$tmp::return_value_propagate_mount_busy
        // 182 file mntput_harness.c line 1080 function do_umount
        CALL umount_tree(do_umount::mnt, cast(bitor(2, 1), c_enum tag-umount_tree_flags))
        // 183 file mntput_harness.c line 1081 function do_umount
        ASSIGN do_umount::1::retval := 0
        // 184 file mntput_harness.c line 1082 function do_umount
        GOTO 10
        // 185 file mntput_harness.c line 1079 function do_umount
     9: DEAD do_umount::$tmp::return_value_propagate_mount_busy
        // 186 
    10: SKIP
        // 187 file mntput_harness.c line 1083 function do_umount
    11: SKIP
        // 188 file mntput_harness.c line 1084 function do_umount
        IF do_umount::1::retval ≠ 0 THEN GOTO 12
        // 189 file mntput_harness.c line 1089 function do_umount
        CALL mnt_dec_count(do_umount::mnt)
        // 190 file mntput_harness.c line 1090 function do_umount
        ASSIGN ghost_caller_put := ghost_caller_put + 1
        // 191 file mntput_harness.c line 1091 function do_umount
        ASSIGN do_umount::1::ref := NULL
        // 192 file mntput_harness.c line 1092 function do_umount
    12: SKIP
        // 193 file mntput_harness.c line 1094 function do_umount
        // Labels: out
    13: CALL unlock_mount_hash()
        // 194 file mntput_harness.c line 1095 function do_umount
        CALL namespace_unlock()
        // 195 file mntput_harness.c line 1096 function do_umount
    14: IF ¬(do_umount::1::ref ≠ NULL) THEN GOTO 15
        // 196 file mntput_harness.c line 1096 function do_umount
        ASSIGN ghost_caller_put := ghost_caller_put + 1
        // 197 file mntput_harness.c line 1096 function do_umount
        CALL mntput_no_expire(do_umount::1::ref)
        // 198 file mntput_harness.c line 1096 function do_umount
    15: SKIP
        // 199 file mntput_harness.c line 1096 function do_umount
        IF 0 ≠ 0 THEN GOTO 14
        // 200 file mntput_harness.c line 1096 function do_umount
        SKIP
        // 201 file mntput_harness.c line 1096 function do_umount
        SKIP
        // 202 file mntput_harness.c line 1097 function do_umount
        EXPRESSION cast(do_umount::1::sb, empty)
        // 203 file mntput_harness.c line 1098 function do_umount
        SET RETURN VALUE do_umount::1::retval
        // 204 file mntput_harness.c line 1098 function do_umount
        DEAD do_umount::1::retval
        // 205 file mntput_harness.c line 1098 function do_umount
        DEAD do_umount::1::sb
        // 206 file mntput_harness.c line 1098 function do_umount
        DEAD do_umount::1::ref
        // 207 file mntput_harness.c line 1098 function do_umount
        GOTO 16
        // 208 file mntput_harness.c line 1099 function do_umount
    16: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

dput /* dput */
        // 808 file mntput_harness.c line 490 function dput
        SKIP
        // 809 file mntput_harness.c line 490 function dput
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

free_vfsmnt /* free_vfsmnt */
        // 672 file mntput_harness.c line 585 function free_vfsmnt
        DECL free_vfsmnt::1::idx : signedbv[32]
        // 673 file mntput_harness.c line 585 function free_vfsmnt
        DECL free_vfsmnt::$tmp::return_value_mnt_idx : signedbv[32]
        // 674 file mntput_harness.c line 585 function free_vfsmnt
        CALL free_vfsmnt::$tmp::return_value_mnt_idx := mnt_idx(free_vfsmnt::mnt)
        // 675 file mntput_harness.c line 585 function free_vfsmnt
        ASSIGN free_vfsmnt::1::idx := free_vfsmnt::$tmp::return_value_mnt_idx
        // 676 file mntput_harness.c line 585 function free_vfsmnt
        DEAD free_vfsmnt::$tmp::return_value_mnt_idx
        // 677 file mntput_harness.c line 587 function free_vfsmnt
        ASSERT ¬(ghost_freed[cast(free_vfsmnt::1::idx, signedbv[64])] ≠ 0) // FreedOnce: struct mount freed twice
        // 678 file mntput_harness.c line 588 function free_vfsmnt
        ASSERT ghost_cleaned[cast(free_vfsmnt::1::idx, signedbv[64])] ≠ 0 // freed without cleanup_mnt()
        // 679 file mntput_harness.c line 589 function free_vfsmnt
        ASSIGN ghost_freed[cast(free_vfsmnt::1::idx, signedbv[64])] := 1
        // 680 file mntput_harness.c line 590 function free_vfsmnt
        DEAD free_vfsmnt::1::idx
        // 681 file mntput_harness.c line 590 function free_vfsmnt
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

fsnotify_vfsmount_delete /* fsnotify_vfsmount_delete */
        // 878 file mntput_harness.c line 489 function fsnotify_vfsmount_delete
        SKIP
        // 879 file mntput_harness.c line 489 function fsnotify_vfsmount_delete
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

ghost_real_refs /* ghost_real_refs */
        // 738 file mntput_harness.c line 264 function ghost_real_refs
        DECL ghost_real_refs::1::idx : signedbv[32]
        // 739 file mntput_harness.c line 264 function ghost_real_refs
        DECL ghost_real_refs::$tmp::return_value_mnt_idx : signedbv[32]
        // 740 file mntput_harness.c line 264 function ghost_real_refs
        CALL ghost_real_refs::$tmp::return_value_mnt_idx := mnt_idx(ghost_real_refs::mnt)
        // 741 file mntput_harness.c line 264 function ghost_real_refs
        ASSIGN ghost_real_refs::1::idx := ghost_real_refs::$tmp::return_value_mnt_idx
        // 742 file mntput_harness.c line 264 function ghost_real_refs
        DEAD ghost_real_refs::$tmp::return_value_mnt_idx
        // 743 file mntput_harness.c line 264 function ghost_real_refs
        DECL ghost_real_refs::1::t : signedbv[32]
        // 744 file mntput_harness.c line 264 function ghost_real_refs
        DECL ghost_real_refs::1::sum : signedbv[32]
        // 745 file mntput_harness.c line 264 function ghost_real_refs
        ASSIGN ghost_real_refs::1::sum := 0
        // 746 file mntput_harness.c line 265 function ghost_real_refs
        ASSIGN ghost_real_refs::1::t := 0
        // 747 file mntput_harness.c line 265 function ghost_real_refs
     1: IF ¬(ghost_real_refs::1::t < 3) THEN GOTO 2
        // 748 file mntput_harness.c line 266 function ghost_real_refs
        ASSIGN ghost_real_refs::1::sum := ghost_real_refs::1::sum + (ghost_transient[cast(ghost_real_refs::1::t, signedbv[64])] ≠ 0 ? 0 : ghost_refs[cast(ghost_real_refs::1::t, signedbv[64])][cast(ghost_real_refs::1::idx, signedbv[64])])
        // 749 file mntput_harness.c line 265 function ghost_real_refs
        ASSIGN ghost_real_refs::1::t := ghost_real_refs::1::t + 1
        // 750 file mntput_harness.c line 265 function ghost_real_refs
        GOTO 1
        // 751 file mntput_harness.c line 265 function ghost_real_refs
     2: SKIP
        // 752 file mntput_harness.c line 267 function ghost_real_refs
        SET RETURN VALUE ghost_real_refs::1::sum
        // 753 file mntput_harness.c line 267 function ghost_real_refs
        DEAD ghost_real_refs::1::sum
        // 754 file mntput_harness.c line 267 function ghost_real_refs
        DEAD ghost_real_refs::1::t
        // 755 file mntput_harness.c line 267 function ghost_real_refs
        DEAD ghost_real_refs::1::idx
        // 756 file mntput_harness.c line 267 function ghost_real_refs
        GOTO 3
        // 757 file mntput_harness.c line 268 function ghost_real_refs
     3: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

hlist_empty /* hlist_empty */
        // 774 file mntput_harness.c line 161 function hlist_empty
        DECL hlist_empty::1::i : signedbv[32]
        // 775 file mntput_harness.c line 161 function hlist_empty
        DECL hlist_empty::1::any : signedbv[32]
        // 776 file mntput_harness.c line 161 function hlist_empty
        ASSIGN hlist_empty::1::any := 0
        // 777 file mntput_harness.c line 162 function hlist_empty
        ASSIGN hlist_empty::1::i := 0
        // 778 file mntput_harness.c line 162 function hlist_empty
     1: IF ¬(hlist_empty::1::i < 1) THEN GOTO 2
        // 779 file mntput_harness.c line 163 function hlist_empty
        ASSIGN hlist_empty::1::any := bitor(hlist_empty::1::any, *hlist_empty::h.on[cast(hlist_empty::1::i, signedbv[64])])
        // 780 file mntput_harness.c line 162 function hlist_empty
        ASSIGN hlist_empty::1::i := hlist_empty::1::i + 1
        // 781 file mntput_harness.c line 162 function hlist_empty
        GOTO 1
        // 782 file mntput_harness.c line 162 function hlist_empty
     2: SKIP
        // 783 file mntput_harness.c line 164 function hlist_empty
        SET RETURN VALUE cast(¬(hlist_empty::1::any ≠ 0), signedbv[32])
        // 784 file mntput_harness.c line 164 function hlist_empty
        DEAD hlist_empty::1::any
        // 785 file mntput_harness.c line 164 function hlist_empty
        DEAD hlist_empty::1::i
        // 786 file mntput_harness.c line 164 function hlist_empty
        GOTO 3
        // 787 file mntput_harness.c line 165 function hlist_empty
     3: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

hlist_move_list /* hlist_move_list */
        // 889 file mntput_harness.c line 169 function hlist_move_list
        ASSIGN *hlist_move_list::new := *hlist_move_list::old
        // 890 file mntput_harness.c line 170 function hlist_move_list
        ASSIGN *hlist_move_list::old.n := 0
        // 891 file mntput_harness.c line 171 function hlist_move_list
        DECL hlist_move_list::1::1::i : signedbv[32]
        // 892 file mntput_harness.c line 171 function hlist_move_list
        ASSIGN hlist_move_list::1::1::i := 0
        // 893 file mntput_harness.c line 171 function hlist_move_list
     1: IF ¬(hlist_move_list::1::1::i < 1) THEN GOTO 2
        // 894 file mntput_harness.c line 171 function hlist_move_list
        ASSIGN *hlist_move_list::old.on[cast(hlist_move_list::1::1::i, signedbv[64])] := 0
        // 895 file mntput_harness.c line 171 function hlist_move_list
        ASSIGN hlist_move_list::1::1::i := hlist_move_list::1::1::i + 1
        // 896 file mntput_harness.c line 171 function hlist_move_list
        GOTO 1
        // 897 file mntput_harness.c line 171 function hlist_move_list
     2: SKIP
        // 898 file mntput_harness.c line 171 function hlist_move_list
        DEAD hlist_move_list::1::1::i
        // 899 file mntput_harness.c line 172 function hlist_move_list
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

holder /* holder */
        // 100 file mntput_harness.c line 1180 function holder
        DECL holder::1::m : struct tag-mount*
        // 101 file mntput_harness.c line 1180 function holder
        ASSIGN holder::1::m := address_of(mounts[cast(0, signedbv[64])])
        // 102 file mntput_harness.c line 1181 function holder
        DECL holder::1::i : signedbv[32]
        // 103 file mntput_harness.c line 1183 function holder
        ASSIGN tid := 1
        // 104 file mntput_harness.c line 1184 function holder
        ASSIGN holder::1::i := 0
        // 105 file mntput_harness.c line 1184 function holder
     1: IF ¬(holder::1::i < 1) THEN GOTO 3
        // 106 file mntput_harness.c line 1185 function holder
        DECL holder::$tmp::return_value_nondet_bool : c_bool[8]
        // 107 file mntput_harness.c line 1185 function holder
        ASSIGN holder::$tmp::return_value_nondet_bool := cast(side_effect statement="nondet" #identifier="nondet_bool" is_nondet_nullable="1", c_bool[8])
        // 108 file mntput_harness.c line 1185 function holder
        IF holder::$tmp::return_value_nondet_bool ≠ 0 THEN GOTO 2
        // 109 file mntput_harness.c line 1185 function holder
        DEAD holder::$tmp::return_value_nondet_bool
        // 110 file mntput_harness.c line 1186 function holder
        GOTO 3
        // 111 file mntput_harness.c line 1185 function holder
     2: DEAD holder::$tmp::return_value_nondet_bool
        // 112 file mntput_harness.c line 1187 function holder
        CALL mntget(address_of(*holder::1::m.mnt))
        // 113 file mntput_harness.c line 1188 function holder
        DECL holder::$tmp::return_value_mnt_idx : signedbv[32]
        // 114 file mntput_harness.c line 1188 function holder
        CALL holder::$tmp::return_value_mnt_idx := mnt_idx(holder::1::m)
        // 115 file mntput_harness.c line 1188 function holder
        ASSERT ¬(ghost_freed[cast(holder::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 116 file mntput_harness.c line 1188 function holder
        DEAD holder::$tmp::return_value_mnt_idx
        // 117 file mntput_harness.c line 1189 function holder
        CALL mntput(address_of(*holder::1::m.mnt))
        // 118 file mntput_harness.c line 1190 function holder
        CALL run_task_work()
        // 119 file mntput_harness.c line 1184 function holder
        ASSIGN holder::1::i := holder::1::i + 1
        // 120 file mntput_harness.c line 1184 function holder
        GOTO 1
        // 121 file mntput_harness.c line 1184 function holder
     3: SKIP
        // 122 file mntput_harness.c line 1192 function holder
        CALL mntput(address_of(*holder::1::m.mnt))
        // 123 file mntput_harness.c line 1193 function holder
        CALL run_task_work()
        // 124 file mntput_harness.c line 1194 function holder
        ASSIGN thread_done[cast(1, signedbv[64])] := cast(1, c_bool[8])
        // 125 file mntput_harness.c line 1195 function holder
        DEAD holder::1::i
        // 126 file mntput_harness.c line 1195 function holder
        DEAD holder::1::m
        // 127 file mntput_harness.c line 1195 function holder
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

init /* init */
        // 865 file mntput_harness.c line 1148 function init
        DECL init::1::i : signedbv[32]
        // 866 file mntput_harness.c line 1150 function init
        ASSIGN init::1::i := 0
        // 867 file mntput_harness.c line 1150 function init
     1: IF ¬(init::1::i < 1) THEN GOTO 2
        // 868 file mntput_harness.c line 1151 function init
        CALL init_mount(address_of(mounts[cast(init::1::i, signedbv[64])]), init::1::i)
        // 869 file mntput_harness.c line 1150 function init
        ASSIGN init::1::i := init::1::i + 1
        // 870 file mntput_harness.c line 1150 function init
        GOTO 1
        // 871 file mntput_harness.c line 1150 function init
     2: SKIP
        // 872 file mntput_harness.c line 1157 function init
        ASSIGN mounts[cast(0, signedbv[64])].mnt_pcp[cast(0, signedbv[64])].mnt_gets := mounts[cast(0, signedbv[64])].mnt_pcp[cast(0, signedbv[64])].mnt_gets + 1
        // 873 file mntput_harness.c line 1159 function init
        ASSIGN ghost_refs[cast(0, signedbv[64])][cast(0, signedbv[64])] := ghost_refs[cast(0, signedbv[64])][cast(0, signedbv[64])] + 1
        // 874 file mntput_harness.c line 1170 function init
        ASSIGN mounts[cast(0, signedbv[64])].mnt_pcp[cast(2 - 1, signedbv[64])].mnt_gets := mounts[cast(0, signedbv[64])].mnt_pcp[cast(2 - 1, signedbv[64])].mnt_gets + 1
        // 875 file mntput_harness.c line 1172 function init
        ASSIGN ghost_refs[cast(1, signedbv[64])][cast(0, signedbv[64])] := 1
        // 876 file mntput_harness.c line 1173 function init
        DEAD init::1::i
        // 877 file mntput_harness.c line 1173 function init
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

init_mount /* init_mount */
        // 904 file mntput_harness.c line 1122 function init_mount
        ASSIGN *init_mount::m.mnt.mnt_sb := address_of(sbs[cast(init_mount::idx, signedbv[64])])
        // 905 file mntput_harness.c line 1123 function init_mount
        ASSIGN *init_mount::m.mnt.mnt_root := address_of(dentries[cast(init_mount::idx, signedbv[64])])
        // 906 file mntput_harness.c line 1124 function init_mount
        ASSIGN *init_mount::m.mnt_mountpoint := address_of(dentries[cast(init_mount::idx, signedbv[64])])
        // 907 file mntput_harness.c line 1125 function init_mount
        ASSIGN sbs[cast(init_mount::idx, signedbv[64])].idx := init_mount::idx
        // 908 file mntput_harness.c line 1130 function init_mount
        ASSIGN *init_mount::m.mnt_pcp[cast(0, signedbv[64])].mnt_gets := cast(1, unsignedbv[32])
        // 909 file mntput_harness.c line 1132 function init_mount
        ASSIGN ghost_refs[cast(0, signedbv[64])][cast(init_mount::idx, signedbv[64])] := 1
        // 910 file mntput_harness.c line 1140 function init_mount
        ASSIGN *init_mount::m.mnt_ns := 1
        // 911 file mntput_harness.c line 1141 function init_mount
        ASSIGN *init_mount::m.mnt_parent := -1
        // 912 file mntput_harness.c line 1142 function init_mount
        ASSIGN ghost_hashed[cast(init_mount::idx, signedbv[64])] := 1
        // 913 file mntput_harness.c line 1144 function init_mount
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

init_task_work /* init_task_work */
        // 733 file mntput_harness.c line 448 function init_task_work
        ASSERT init_task_work::func = address_of(__cleanup_mnt) // task work is always __cleanup_mnt()
        // 734 file mntput_harness.c line 449 function init_task_work
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

legitimize_mnt /* legitimize_mnt */
        // 456 file mntput_harness.c line 633 function legitimize_mnt
        DECL legitimize_mnt::1::res : signedbv[32]
        // 457 file mntput_harness.c line 633 function legitimize_mnt
        DECL legitimize_mnt::$tmp::return_value___legitimize_mnt : signedbv[32]
        // 458 file mntput_harness.c line 633 function legitimize_mnt
        CALL legitimize_mnt::$tmp::return_value___legitimize_mnt := __legitimize_mnt(legitimize_mnt::bastard, legitimize_mnt::seq)
        // 459 file mntput_harness.c line 633 function legitimize_mnt
        ASSIGN legitimize_mnt::1::res := legitimize_mnt::$tmp::return_value___legitimize_mnt
        // 460 file mntput_harness.c line 633 function legitimize_mnt
        DEAD legitimize_mnt::$tmp::return_value___legitimize_mnt
        // 461 file mntput_harness.c line 634 function legitimize_mnt
        IF legitimize_mnt::1::res ≠ 0 THEN GOTO 1
        // 462 file mntput_harness.c line 635 function legitimize_mnt
        SET RETURN VALUE cast(1, c_bool[8])
        // 463 file mntput_harness.c line 635 function legitimize_mnt
        DEAD legitimize_mnt::1::res
        // 464 file mntput_harness.c line 635 function legitimize_mnt
        GOTO 3
        // 465 file mntput_harness.c line 635 function legitimize_mnt
     1: SKIP
        // 466 file mntput_harness.c line 636 function legitimize_mnt
        IF ¬(legitimize_mnt::1::res < 0) THEN GOTO 2
        // 467 file mntput_harness.c line 637 function legitimize_mnt
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 468 file mntput_harness.c line 638 function legitimize_mnt
        CALL mntput(legitimize_mnt::bastard)
        // 469 file mntput_harness.c line 639 function legitimize_mnt
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(1, c_bool[8])
        // 470 file mntput_harness.c line 640 function legitimize_mnt
     2: SKIP
        // 471 file mntput_harness.c line 641 function legitimize_mnt
        SET RETURN VALUE cast(0, c_bool[8])
        // 472 file mntput_harness.c line 641 function legitimize_mnt
        DEAD legitimize_mnt::1::res
        // 473 file mntput_harness.c line 641 function legitimize_mnt
        GOTO 3
        // 474 file mntput_harness.c line 642 function legitimize_mnt
     3: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

lock_mount_hash /* lock_mount_hash */
        // 682 file mntput_harness.c line 379 function lock_mount_hash
        CALL write_seqlock(address_of(mount_lock))
        // 683 file mntput_harness.c line 380 function lock_mount_hash
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

main /* main */
        // 0 file mntput_harness.c line 1238 function main
        DECL main::1::retval : signedbv[32]
        // 1 file mntput_harness.c line 1238 function main
        ASSIGN main::1::retval := 0
        // 2 file mntput_harness.c line 1238 function main
        DECL main::1::i : signedbv[32]
        // 3 file mntput_harness.c line 1240 function main
        ASSIGN tid := 0
        // 4 file mntput_harness.c line 1241 function main
        CALL init()
        // 5 file mntput_harness.c line 1243 function main
        START THREAD 1
        // 6 file mntput_harness.c line 1243 function main
        GOTO 2
        // 7 no location
     1: SKIP
        // 8 file mntput_harness.c line 1243 function main
        CALL holder()
        // 9 file mntput_harness.c line 1243 function main
        END THREAD
        // 10 no location
     2: SKIP
        // 11 file mntput_harness.c line 1245 function main
        START THREAD 3
        // 12 file mntput_harness.c line 1245 function main
        GOTO 4
        // 13 no location
     3: SKIP
        // 14 file mntput_harness.c line 1245 function main
        CALL walker()
        // 15 file mntput_harness.c line 1245 function main
        END THREAD
        // 16 no location
     4: SKIP
        // 17 file mntput_harness.c line 1251 function main
        CALL main::1::retval := do_umount(address_of(mounts[cast(0, signedbv[64])]), 0)
        // 18 file mntput_harness.c line 1262 function main
        CALL run_task_work()
        // 19 file mntput_harness.c line 1266 function main
        ASSERT ghost_caller_put = 1 // CallerPutOnce: do_umount() dropped the caller's reference once
        // 20 file mntput_harness.c line 1267 function main
        ASSERT ghost_refs[cast(0, signedbv[64])][cast(0, signedbv[64])] = (main::1::retval ≠ 0 ? 1 : 0) // ledger: U holds the own reference iff the umount was refused
        // 21 file mntput_harness.c line 1270 function main
        IF ¬(main::1::retval = 0) THEN GOTO 5
        // 22 file mntput_harness.c line 1272 function main
        ASSERT ghost_refs[cast(1, signedbv[64])][cast(0, signedbv[64])] = 0 // SyncClean: the holder still has a reference
        // 23 file mntput_harness.c line 1273 function main
        ASSERT ghost_transient[cast(2, signedbv[64])] ≠ 0 ∨ ghost_refs[cast(2, signedbv[64])][cast(0, signedbv[64])] = 0 // SyncClean: the walker still has a reference
        // 24 file mntput_harness.c line 1274 function main
        ASSERT ghost_cleaned[cast(0, signedbv[64])] = 1 ∧ ghost_cleaner[cast(0, signedbv[64])] = 0 // SyncClean: cleanup_mnt() did not run from umount(2)
        // 25 file mntput_harness.c line 1275 function main
        ASSERT ghost_sb_torn[cast(0, signedbv[64])] ≠ 0 // SyncClean: the superblock is still up after umount(2)
        // 26 file mntput_harness.c line 1276 function main
     5: SKIP
        // 27 file mntput_harness.c line 1280 function main
        ASSUME thread_done[cast(1, signedbv[64])] ≠ 0
        // 28 file mntput_harness.c line 1281 function main
        ASSUME thread_done[cast(2, signedbv[64])] ≠ 0
        // 29 file mntput_harness.c line 1284 function main
        ASSIGN main::1::i := 0
        // 30 file mntput_harness.c line 1284 function main
     6: IF ¬(main::1::i < 1) THEN GOTO 9
        // 31 file mntput_harness.c line 1285 function main
        IF ¬(ghost_umounted[cast(main::1::i, signedbv[64])] ≠ 0) THEN GOTO 7
        // 32 file mntput_harness.c line 1286 function main
        ASSERT ghost_cleaned[cast(main::1::i, signedbv[64])] = 1 // Freed: an unmounted mount was never cleaned up (leak)
        // 33 file mntput_harness.c line 1287 function main
        ASSERT ghost_freed[cast(main::1::i, signedbv[64])] = 1 // Freed: an unmounted mount was never freed (leak)
        // 34 file mntput_harness.c line 1288 function main
        ASSERT (ghost_refs[cast(0, signedbv[64])][cast(main::1::i, signedbv[64])] = 0 ∧ ghost_refs[cast(1, signedbv[64])][cast(main::1::i, signedbv[64])] = 0) ∧ ghost_refs[cast(2, signedbv[64])][cast(main::1::i, signedbv[64])] = 0 // ledger: a reference to an unmounted mount survives
        // 35 file mntput_harness.c line 1290 function main
        GOTO 8
        // 36 file mntput_harness.c line 1291 function main
     7: ASSERT ¬(ghost_cleaned[cast(main::1::i, signedbv[64])] ≠ 0) ∧ ¬(ghost_freed[cast(main::1::i, signedbv[64])] ≠ 0) // a mounted mount was cleaned up
        // 37 file mntput_harness.c line 1292 function main
        DECL main::$tmp::return_value_mnt_get_count : signedbv[32]
        // 38 file mntput_harness.c line 1292 function main
        CALL main::$tmp::return_value_mnt_get_count := mnt_get_count(address_of(mounts[cast(main::1::i, signedbv[64])]))
        // 39 file mntput_harness.c line 1292 function main
        ASSERT main::$tmp::return_value_mnt_get_count = 1 // a mounted mount does not hold exactly its own reference
        // 40 file mntput_harness.c line 1292 function main
        DEAD main::$tmp::return_value_mnt_get_count
        // 41 file mntput_harness.c line 1293 function main
        ASSERT (ghost_refs[cast(0, signedbv[64])][cast(main::1::i, signedbv[64])] = 1 ∧ ghost_refs[cast(1, signedbv[64])][cast(main::1::i, signedbv[64])] = 0) ∧ ghost_refs[cast(2, signedbv[64])][cast(main::1::i, signedbv[64])] = 0 // ledger: a mounted mount is held by somebody other than itself
        // 42 file mntput_harness.c line 1295 function main
     8: SKIP
        // 43 file mntput_harness.c line 1284 function main
        ASSIGN main::1::i := main::1::i + 1
        // 44 file mntput_harness.c line 1284 function main
        GOTO 6
        // 45 file mntput_harness.c line 1284 function main
     9: SKIP
        // 46 file mntput_harness.c line 1297 function main
        ASSERT ghost_gps ≤ 1 // more than one grace period for one batch
        // 47 file mntput_harness.c line 1298 function main
        SET RETURN VALUE 0
        // 48 file mntput_harness.c line 1298 function main
        DEAD main::1::i
        // 49 file mntput_harness.c line 1298 function main
        DEAD main::1::retval
        // 50 file mntput_harness.c line 1298 function main
        GOTO 10
        // 51 file mntput_harness.c line 1299 function main
    10: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_dec_count /* mnt_dec_count */
        // 887 file mntput_harness.c line 538 function mnt_dec_count
        CALL percpu_add(mnt_dec_count::mnt, cast(cast(address_of(*mnt_dec_count::mnt.mnt_pcp[0].mnt_puts), signedbv[8]*) - cast(address_of(*mnt_dec_count::mnt.mnt_pcp[0]), signedbv[8]*) = cast(4, signedbv[64]), signedbv[32]), unary+(1), (cast(address_of(*mnt_dec_count::mnt.mnt_pcp[0].mnt_puts), signedbv[8]*) - cast(address_of(*mnt_dec_count::mnt.mnt_pcp[0]), signedbv[8]*) = cast(4, signedbv[64]) ? -1 : unary+(1)))
        // 888 file mntput_harness.c line 545 function mnt_dec_count
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_del_instance /* mnt_del_instance */
        // 885 file mntput_harness.c line 503 function mnt_del_instance
        SKIP
        // 886 file mntput_harness.c line 503 function mnt_del_instance
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_free_id /* mnt_free_id */
        // 801 file mntput_harness.c line 492 function mnt_free_id
        SKIP
        // 802 file mntput_harness.c line 492 function mnt_free_id
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_get_count /* mnt_get_count */
        // 534 file mntput_harness.c line 565 function mnt_get_count
        DECL mnt_get_count::1::gets : unsignedbv[32]
        // 535 file mntput_harness.c line 565 function mnt_get_count
        ASSIGN mnt_get_count::1::gets := cast(0, unsignedbv[32])
        // 536 file mntput_harness.c line 565 function mnt_get_count
        DECL mnt_get_count::1::puts : unsignedbv[32]
        // 537 file mntput_harness.c line 565 function mnt_get_count
        ASSIGN mnt_get_count::1::puts := cast(0, unsignedbv[32])
        // 538 file mntput_harness.c line 566 function mnt_get_count
        DECL mnt_get_count::1::cpu : signedbv[32]
        // 539 file mntput_harness.c line 568 function mnt_get_count
        DECL mnt_get_count::$tmp::return_value_mnt_idx : signedbv[32]
        // 540 file mntput_harness.c line 568 function mnt_get_count
        CALL mnt_get_count::$tmp::return_value_mnt_idx := mnt_idx(mnt_get_count::mnt)
        // 541 file mntput_harness.c line 568 function mnt_get_count
        ASSERT ¬(ghost_freed[cast(mnt_get_count::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 542 file mntput_harness.c line 568 function mnt_get_count
        DEAD mnt_get_count::$tmp::return_value_mnt_idx
        // 543 file mntput_harness.c line 570 function mnt_get_count
        ASSIGN mnt_get_count::1::cpu := 0
        // 544 file mntput_harness.c line 570 function mnt_get_count
     1: IF ¬(mnt_get_count::1::cpu < 2) THEN GOTO 2
        // 545 file mntput_harness.c line 571 function mnt_get_count
        ASSIGN mnt_get_count::1::puts := mnt_get_count::1::puts + *(address_of(*mnt_get_count::mnt.mnt_pcp[cast(mnt_get_count::1::cpu, signedbv[64])])).mnt_puts
        // 546 file mntput_harness.c line 570 function mnt_get_count
        ASSIGN mnt_get_count::1::cpu := mnt_get_count::1::cpu + 1
        // 547 file mntput_harness.c line 570 function mnt_get_count
        GOTO 1
        // 548 file mntput_harness.c line 570 function mnt_get_count
     2: SKIP
        // 549 file mntput_harness.c line 572 function mnt_get_count
        FENCE WW RR RW WR
        // 550 file mntput_harness.c line 573 function mnt_get_count
        ASSIGN mnt_get_count::1::cpu := 0
        // 551 file mntput_harness.c line 573 function mnt_get_count
     3: IF ¬(mnt_get_count::1::cpu < 2) THEN GOTO 4
        // 552 file mntput_harness.c line 574 function mnt_get_count
        ASSIGN mnt_get_count::1::gets := mnt_get_count::1::gets + *(address_of(*mnt_get_count::mnt.mnt_pcp[cast(mnt_get_count::1::cpu, signedbv[64])])).mnt_gets
        // 553 file mntput_harness.c line 573 function mnt_get_count
        ASSIGN mnt_get_count::1::cpu := mnt_get_count::1::cpu + 1
        // 554 file mntput_harness.c line 573 function mnt_get_count
        GOTO 3
        // 555 file mntput_harness.c line 573 function mnt_get_count
     4: SKIP
        // 556 file mntput_harness.c line 576 function mnt_get_count
        SET RETURN VALUE cast(mnt_get_count::1::gets - mnt_get_count::1::puts, signedbv[32])
        // 557 file mntput_harness.c line 576 function mnt_get_count
        DEAD mnt_get_count::1::cpu
        // 558 file mntput_harness.c line 576 function mnt_get_count
        DEAD mnt_get_count::1::puts
        // 559 file mntput_harness.c line 576 function mnt_get_count
        DEAD mnt_get_count::1::gets
        // 560 file mntput_harness.c line 576 function mnt_get_count
        GOTO 5
        // 561 file mntput_harness.c line 581 function mnt_get_count
     5: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_get_writers /* mnt_get_writers */
        // 880 file mntput_harness.c line 487 function mnt_get_writers
        SET RETURN VALUE 0
        // 881 file mntput_harness.c line 487 function mnt_get_writers
        GOTO 1
        // 882 file mntput_harness.c line 487 function mnt_get_writers
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_has_parent /* mnt_has_parent */
        // 795 file mntput_harness.c line 225 function mnt_has_parent
        DECL mnt_has_parent::$tmp::return_value_mnt_idx : signedbv[32]
        // 796 file mntput_harness.c line 225 function mnt_has_parent
        CALL mnt_has_parent::$tmp::return_value_mnt_idx := mnt_idx(cast(mnt_has_parent::mnt, struct tag-mount*))
        // 797 file mntput_harness.c line 225 function mnt_has_parent
        SET RETURN VALUE cast(mnt_has_parent::$tmp::return_value_mnt_idx ≠ *mnt_has_parent::mnt.mnt_parent, signedbv[32])
        // 798 file mntput_harness.c line 225 function mnt_has_parent
        DEAD mnt_has_parent::$tmp::return_value_mnt_idx
        // 799 file mntput_harness.c line 225 function mnt_has_parent
        GOTO 1
        // 800 file mntput_harness.c line 226 function mnt_has_parent
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_idx /* mnt_idx */
        // 735 file mntput_harness.c line 240 function mnt_idx
        SET RETURN VALUE cast(mnt_idx::mnt - address_of(mounts[0]), signedbv[32])
        // 736 file mntput_harness.c line 240 function mnt_idx
        GOTO 1
        // 737 file mntput_harness.c line 241 function mnt_idx
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_inc_count /* mnt_inc_count */
        // 788 file mntput_harness.c line 523 function mnt_inc_count
        CALL percpu_add(mnt_inc_count::mnt, cast(cast(address_of(*mnt_inc_count::mnt.mnt_pcp[0].mnt_gets), signedbv[8]*) - cast(address_of(*mnt_inc_count::mnt.mnt_pcp[0]), signedbv[8]*) = cast(4, signedbv[64]), signedbv[32]), unary+(1), (cast(address_of(*mnt_inc_count::mnt.mnt_pcp[0].mnt_gets), signedbv[8]*) - cast(address_of(*mnt_inc_count::mnt.mnt_pcp[0]), signedbv[8]*) = cast(4, signedbv[64]) ? -1 : unary+(1)))
        // 789 file mntput_harness.c line 530 function mnt_inc_count
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mnt_pin_kill /* mnt_pin_kill */
        // 900 file mntput_harness.c line 488 function mnt_pin_kill
        ASSERT 0 ≠ 0 // mnt_pins is empty
        // 901 file mntput_harness.c line 488 function mnt_pin_kill
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntget /* mntget */
        // 295 file mntput_harness.c line 918 function mntget
        IF ¬(mntget::mnt ≠ NULL) THEN GOTO 1
        // 296 file mntput_harness.c line 919 function mntget
        DECL mntget::$tmp::return_value_real_mount : struct tag-mount*
        // 297 file mntput_harness.c line 919 function mntget
        CALL mntget::$tmp::return_value_real_mount := real_mount(mntget::mnt)
        // 298 file mntput_harness.c line 919 function mntget
        CALL mnt_inc_count(mntget::$tmp::return_value_real_mount)
        // 299 file mntput_harness.c line 919 function mntget
        DEAD mntget::$tmp::return_value_real_mount
        // 300 file mntput_harness.c line 919 function mntget
     1: SKIP
        // 301 file mntput_harness.c line 920 function mntget
        SET RETURN VALUE mntget::mnt
        // 302 file mntput_harness.c line 920 function mntget
        GOTO 2
        // 303 file mntput_harness.c line 921 function mntget
     2: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput /* mntput */
        // 475 file mntput_harness.c line 906 function mntput
        IF ¬(mntput::mnt ≠ NULL) THEN GOTO 2
        // 476 file mntput_harness.c line 907 function mntput
        DECL mntput::1::1::m : struct tag-mount*
        // 477 file mntput_harness.c line 907 function mntput
        DECL mntput::$tmp::return_value_real_mount : struct tag-mount*
        // 478 file mntput_harness.c line 907 function mntput
        CALL mntput::$tmp::return_value_real_mount := real_mount(mntput::mnt)
        // 479 file mntput_harness.c line 907 function mntput
        ASSIGN mntput::1::1::m := mntput::$tmp::return_value_real_mount
        // 480 file mntput_harness.c line 907 function mntput
        DEAD mntput::$tmp::return_value_real_mount
        // 481 file mntput_harness.c line 908 function mntput
        DECL mntput::$tmp::return_value_mnt_idx : signedbv[32]
        // 482 file mntput_harness.c line 908 function mntput
        CALL mntput::$tmp::return_value_mnt_idx := mnt_idx(mntput::1::1::m)
        // 483 file mntput_harness.c line 908 function mntput
        ASSERT ¬(ghost_freed[cast(mntput::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 484 file mntput_harness.c line 908 function mntput
        DEAD mntput::$tmp::return_value_mnt_idx
        // 485 file mntput_harness.c line 910 function mntput
        IF ¬(*mntput::1::1::m.mnt_expiry_mark ≠ 0) THEN GOTO 1
        // 486 file mntput_harness.c line 911 function mntput
        ASSIGN *mntput::1::1::m.mnt_expiry_mark := 0
        // 487 file mntput_harness.c line 911 function mntput
     1: SKIP
        // 488 file mntput_harness.c line 912 function mntput
        CALL mntput_no_expire(mntput::1::1::m)
        // 489 file mntput_harness.c line 913 function mntput
        DEAD mntput::1::1::m
        // 490 file mntput_harness.c line 913 function mntput
     2: SKIP
        // 491 file mntput_harness.c line 914 function mntput
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_final_locked /* mntput_final_locked */
        // 435 file mntput_harness.c line 684 function mntput_final_locked
        DECL mntput_final_locked::$tmp::return_value_mnt_idx : signedbv[32]
        // 436 file mntput_harness.c line 684 function mntput_final_locked
        CALL mntput_final_locked::$tmp::return_value_mnt_idx := mnt_idx(mntput_final_locked::mnt)
        // 437 file mntput_harness.c line 684 function mntput_final_locked
        ASSERT ¬(ghost_freed[cast(mntput_final_locked::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 438 file mntput_harness.c line 684 function mntput_final_locked
        DEAD mntput_final_locked::$tmp::return_value_mnt_idx
        // 439 file mntput_harness.c line 686 function mntput_final_locked
        DECL mntput_final_locked::$tmp::return_value_ghost_real_refs : signedbv[32]
        // 440 file mntput_harness.c line 686 function mntput_final_locked
        CALL mntput_final_locked::$tmp::return_value_ghost_real_refs := ghost_real_refs(mntput_final_locked::mnt)
        // 441 file mntput_harness.c line 686 function mntput_final_locked
        ASSERT mntput_final_locked::$tmp::return_value_ghost_real_refs = 0 // DoomedIsLast: doomed while a counted reference exists
        // 442 file mntput_harness.c line 686 function mntput_final_locked
        DEAD mntput_final_locked::$tmp::return_value_ghost_real_refs
        // 443 file mntput_harness.c line 688 function mntput_final_locked
        DECL mntput_final_locked::1::1::__c : signedbv[32]
        // 444 file mntput_harness.c line 688 function mntput_final_locked
        ASSIGN mntput_final_locked::1::1::__c := cast(¬(¬(bitand(*mntput_final_locked::mnt.mnt.mnt_flags, 16777216) ≠ 0)), signedbv[32])
        // 445 file mntput_harness.c line 688 function mntput_final_locked
        ASSERT ¬(mntput_final_locked::1::1::__c ≠ 0) // WARN_ON(mnt->mnt.mnt_flags & 0x1000000)
        // 446 file mntput_harness.c line 688 function mntput_final_locked
        EXPRESSION mntput_final_locked::1::1::__c
        // 447 file mntput_harness.c line 688 function mntput_final_locked
        DEAD mntput_final_locked::1::1::__c
        // 448 file mntput_harness.c line 689 function mntput_final_locked
        ASSIGN *mntput_final_locked::mnt.mnt.mnt_flags := bitor(*mntput_final_locked::mnt.mnt.mnt_flags, 16777216)
        // 449 file mntput_harness.c line 691 function mntput_final_locked
        CALL mnt_del_instance(mntput_final_locked::mnt)
        // 450 file mntput_harness.c line 695 function mntput_final_locked
        DECL mntput_final_locked::1::2::__c : signedbv[32]
        // 451 file mntput_harness.c line 695 function mntput_final_locked
        ASSIGN mntput_final_locked::1::2::__c := cast(¬(¬(*mntput_final_locked::mnt.nr_children ≠ 0)), signedbv[32])
        // 452 file mntput_harness.c line 695 function mntput_final_locked
        ASSERT ¬(mntput_final_locked::1::2::__c ≠ 0) // WARN_ON(mnt->nr_children)
        // 453 file mntput_harness.c line 695 function mntput_final_locked
        EXPRESSION mntput_final_locked::1::2::__c
        // 454 file mntput_harness.c line 695 function mntput_final_locked
        DEAD mntput_final_locked::1::2::__c
        // 455 file mntput_harness.c line 697 function mntput_final_locked
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_no_expire /* mntput_no_expire */
        // 397 file mntput_harness.c line 786 function mntput_no_expire
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(1, c_bool[8])
        // 398 file mntput_harness.c line 787 function mntput_no_expire
        DECL mntput_no_expire::$tmp::return_value_mnt_idx : signedbv[32]
        // 399 file mntput_harness.c line 787 function mntput_no_expire
        CALL mntput_no_expire::$tmp::return_value_mnt_idx := mnt_idx(mntput_no_expire::mnt)
        // 400 file mntput_harness.c line 787 function mntput_no_expire
        ASSERT ¬(ghost_freed[cast(mntput_no_expire::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 401 file mntput_harness.c line 787 function mntput_no_expire
        DEAD mntput_no_expire::$tmp::return_value_mnt_idx
        // 402 file mntput_harness.c line 788 function mntput_no_expire
        IF ¬(*mntput_no_expire::mnt.mnt_ns ≠ 0) THEN GOTO 1
        // 403 file mntput_harness.c line 800 function mntput_no_expire
        FENCE WW
        // 404 file mntput_harness.c line 801 function mntput_no_expire
        CALL mnt_dec_count(mntput_no_expire::mnt)
        // 405 file mntput_harness.c line 811 function mntput_no_expire
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 406 file mntput_harness.c line 812 function mntput_no_expire
        GOTO 2
        // 407 file mntput_harness.c line 814 function mntput_no_expire
     1: SKIP
        // 408 file mntput_harness.c line 815 function mntput_no_expire
        CALL mntput_no_expire_slowpath(mntput_no_expire::mnt)
        // 409 file mntput_harness.c line 816 function mntput_no_expire
     2: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_no_expire_slowpath /* mntput_no_expire_slowpath */
        // 822 file mntput_harness.c line 718 function mntput_no_expire_slowpath
        DECL mntput_no_expire_slowpath::1::list : struct tag-list_head
        // 823 file mntput_harness.c line 718 function mntput_no_expire_slowpath
        ASSIGN mntput_no_expire_slowpath::1::list := { 0 }
        // 824 file mntput_harness.c line 719 function mntput_no_expire_slowpath
        DECL mntput_no_expire_slowpath::1::count : signedbv[32]
        // 825 file mntput_harness.c line 721 function mntput_no_expire_slowpath
        DECL mntput_no_expire_slowpath::$tmp::return_value_mnt_idx : signedbv[32]
        // 826 file mntput_harness.c line 721 function mntput_no_expire_slowpath
        CALL mntput_no_expire_slowpath::$tmp::return_value_mnt_idx := mnt_idx(mntput_no_expire_slowpath::mnt)
        // 827 file mntput_harness.c line 721 function mntput_no_expire_slowpath
        ASSERT ¬(ghost_freed[cast(mntput_no_expire_slowpath::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 828 file mntput_harness.c line 721 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::$tmp::return_value_mnt_idx
        // 829 file mntput_harness.c line 722 function mntput_no_expire_slowpath
        DECL mntput_no_expire_slowpath::1::1::__c : signedbv[32]
        // 830 file mntput_harness.c line 722 function mntput_no_expire_slowpath
        ASSIGN mntput_no_expire_slowpath::1::1::__c := cast(¬(¬(*mntput_no_expire_slowpath::mnt.mnt_ns ≠ 0)), signedbv[32])
        // 831 file mntput_harness.c line 722 function mntput_no_expire_slowpath
        ASSERT ¬(mntput_no_expire_slowpath::1::1::__c ≠ 0) // WARN_ON(mnt->mnt_ns)
        // 832 file mntput_harness.c line 722 function mntput_no_expire_slowpath
        EXPRESSION mntput_no_expire_slowpath::1::1::__c
        // 833 file mntput_harness.c line 722 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::1::__c
        // 834 file mntput_harness.c line 723 function mntput_no_expire_slowpath
        CALL lock_mount_hash()
        // 835 file mntput_harness.c line 728 function mntput_no_expire_slowpath
        FENCE WW RR RW WR
        // 836 file mntput_harness.c line 729 function mntput_no_expire_slowpath
        CALL mnt_dec_count(mntput_no_expire_slowpath::mnt)
        // 837 file mntput_harness.c line 730 function mntput_no_expire_slowpath
        CALL mntput_no_expire_slowpath::1::count := mnt_get_count(mntput_no_expire_slowpath::mnt)
        // 838 file mntput_harness.c line 731 function mntput_no_expire_slowpath
        IF ¬(mntput_no_expire_slowpath::1::count ≠ 0) THEN GOTO 1
        // 839 file mntput_harness.c line 732 function mntput_no_expire_slowpath
        DECL mntput_no_expire_slowpath::1::2::1::__c : signedbv[32]
        // 840 file mntput_harness.c line 732 function mntput_no_expire_slowpath
        ASSIGN mntput_no_expire_slowpath::1::2::1::__c := cast(¬(¬(mntput_no_expire_slowpath::1::count < 0)), signedbv[32])
        // 841 file mntput_harness.c line 732 function mntput_no_expire_slowpath
        ASSERT ¬(mntput_no_expire_slowpath::1::2::1::__c ≠ 0) // WARN_ON(count < 0)
        // 842 file mntput_harness.c line 732 function mntput_no_expire_slowpath
        EXPRESSION mntput_no_expire_slowpath::1::2::1::__c
        // 843 file mntput_harness.c line 732 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::2::1::__c
        // 844 file mntput_harness.c line 733 function mntput_no_expire_slowpath
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 845 file mntput_harness.c line 734 function mntput_no_expire_slowpath
        CALL unlock_mount_hash()
        // 846 file mntput_harness.c line 735 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::count
        // 847 file mntput_harness.c line 735 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::list
        // 848 file mntput_harness.c line 735 function mntput_no_expire_slowpath
        GOTO 3
        // 849 file mntput_harness.c line 736 function mntput_no_expire_slowpath
     1: SKIP
        // 850 file mntput_harness.c line 737 function mntput_no_expire_slowpath
        IF ¬(bitand(*mntput_no_expire_slowpath::mnt.mnt.mnt_flags, 16777216) ≠ 0) THEN GOTO 2
        // 851 file mntput_harness.c line 738 function mntput_no_expire_slowpath
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 852 file mntput_harness.c line 739 function mntput_no_expire_slowpath
        CALL unlock_mount_hash()
        // 853 file mntput_harness.c line 740 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::count
        // 854 file mntput_harness.c line 740 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::list
        // 855 file mntput_harness.c line 740 function mntput_no_expire_slowpath
        GOTO 3
        // 856 file mntput_harness.c line 741 function mntput_no_expire_slowpath
     2: SKIP
        // 857 file mntput_harness.c line 742 function mntput_no_expire_slowpath
        CALL mntput_final_locked(mntput_no_expire_slowpath::mnt, address_of(mntput_no_expire_slowpath::1::list))
        // 858 file mntput_harness.c line 743 function mntput_no_expire_slowpath
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 859 file mntput_harness.c line 744 function mntput_no_expire_slowpath
        CALL unlock_mount_hash()
        // 860 file mntput_harness.c line 745 function mntput_no_expire_slowpath
        CALL shrink_dentry_list(address_of(mntput_no_expire_slowpath::1::list))
        // 861 file mntput_harness.c line 746 function mntput_no_expire_slowpath
        CALL mntput_queue_cleanup(mntput_no_expire_slowpath::mnt)
        // 862 file mntput_harness.c line 747 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::count
        // 863 file mntput_harness.c line 747 function mntput_no_expire_slowpath
        DEAD mntput_no_expire_slowpath::1::list
        // 864 file mntput_harness.c line 747 function mntput_no_expire_slowpath
     3: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_queue_cleanup /* mntput_queue_cleanup */
        // 410 file mntput_harness.c line 702 function mntput_queue_cleanup
        IF bitand(*mntput_queue_cleanup::mnt.mnt.mnt_flags, 16384) ≠ 0 THEN GOTO 5
        // 411 file mntput_harness.c line 703 function mntput_queue_cleanup
        DECL mntput_queue_cleanup::1::1::task : struct tag-task_struct*
        // 412 file mntput_harness.c line 703 function mntput_queue_cleanup
        ASSIGN mntput_queue_cleanup::1::1::task := address_of(tasks[cast(tid, signedbv[64])])
        // 413 file mntput_harness.c line 704 function mntput_queue_cleanup
        IF bitand(*mntput_queue_cleanup::1::1::task.flags, cast(2097152, unsignedbv[32])) ≠ 0 THEN GOTO 2
        // 414 file mntput_harness.c line 705 function mntput_queue_cleanup
        CALL init_task_work(address_of(*mntput_queue_cleanup::mnt.mnt_rcu), address_of(__cleanup_mnt))
        // 415 file mntput_harness.c line 706 function mntput_queue_cleanup
        DECL mntput_queue_cleanup::$tmp::return_value_task_work_add : signedbv[32]
        // 416 file mntput_harness.c line 706 function mntput_queue_cleanup
        CALL mntput_queue_cleanup::$tmp::return_value_task_work_add := task_work_add(mntput_queue_cleanup::1::1::task, address_of(*mntput_queue_cleanup::mnt.mnt_rcu), 1)
        // 417 file mntput_harness.c line 706 function mntput_queue_cleanup
        IF mntput_queue_cleanup::$tmp::return_value_task_work_add ≠ 0 THEN GOTO 1
        // 418 file mntput_harness.c line 706 function mntput_queue_cleanup
        DEAD mntput_queue_cleanup::$tmp::return_value_task_work_add
        // 419 file mntput_harness.c line 707 function mntput_queue_cleanup
        DEAD mntput_queue_cleanup::1::1::task
        // 420 file mntput_harness.c line 707 function mntput_queue_cleanup
        GOTO 6
        // 421 file mntput_harness.c line 706 function mntput_queue_cleanup
     1: DEAD mntput_queue_cleanup::$tmp::return_value_task_work_add
        // 422 file mntput_harness.c line 708 function mntput_queue_cleanup
     2: SKIP
        // 423 file mntput_harness.c line 709 function mntput_queue_cleanup
        ASSERT 0 ≠ 0 // kthread cleanup path
        // 424 file mntput_harness.c line 709 function mntput_queue_cleanup
        IF ¬(0 ≠ 0) THEN GOTO 4
        // 425 file mntput_harness.c line 710 function mntput_queue_cleanup
     3: SKIP
        // 426 file mntput_harness.c line 710 function mntput_queue_cleanup
        IF 0 ≠ 0 THEN GOTO 3
        // 427 file mntput_harness.c line 710 function mntput_queue_cleanup
        SKIP
        // 428 file mntput_harness.c line 710 function mntput_queue_cleanup
        SKIP
        // 429 file mntput_harness.c line 710 function mntput_queue_cleanup
     4: SKIP
        // 430 file mntput_harness.c line 711 function mntput_queue_cleanup
        DEAD mntput_queue_cleanup::1::1::task
        // 431 file mntput_harness.c line 711 function mntput_queue_cleanup
        GOTO 6
        // 432 file mntput_harness.c line 712 function mntput_queue_cleanup
     5: SKIP
        // 433 file mntput_harness.c line 713 function mntput_queue_cleanup
        CALL cleanup_mnt(mntput_queue_cleanup::mnt)
        // 434 file mntput_harness.c line 714 function mntput_queue_cleanup
     6: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_unheld /* mntput_unheld */
        // 375 file mntput_harness.c line 829 function mntput_unheld
        DECL mntput_unheld::1::1::__c : signedbv[32]
        // 376 file mntput_harness.c line 829 function mntput_unheld
        ASSIGN mntput_unheld::1::1::__c := cast(¬(¬(*mntput_unheld::mnt.mnt_ns ≠ 0)), signedbv[32])
        // 377 file mntput_harness.c line 829 function mntput_unheld
        ASSERT ¬(mntput_unheld::1::1::__c ≠ 0) // WARN_ON(mnt->mnt_ns)
        // 378 file mntput_harness.c line 829 function mntput_unheld
        EXPRESSION mntput_unheld::1::1::__c
        // 379 file mntput_harness.c line 829 function mntput_unheld
        DEAD mntput_unheld::1::1::__c
        // 380 file mntput_harness.c line 837 function mntput_unheld
        DECL mntput_unheld::$tmp::return_value_mnt_get_count : signedbv[32]
        // 381 file mntput_harness.c line 837 function mntput_unheld
        CALL mntput_unheld::$tmp::return_value_mnt_get_count := mnt_get_count(mntput_unheld::mnt)
        // 382 file mntput_harness.c line 837 function mntput_unheld
        IF ¬(mntput_unheld::$tmp::return_value_mnt_get_count ≠ 1) THEN GOTO 1
        // 383 file mntput_harness.c line 837 function mntput_unheld
        DEAD mntput_unheld::$tmp::return_value_mnt_get_count
        // 384 file mntput_harness.c line 838 function mntput_unheld
        SET RETURN VALUE cast(0, c_bool[8])
        // 385 file mntput_harness.c line 838 function mntput_unheld
        GOTO 2
        // 386 file mntput_harness.c line 837 function mntput_unheld
     1: DEAD mntput_unheld::$tmp::return_value_mnt_get_count
        // 387 file mntput_harness.c line 840 function mntput_unheld
        CALL mnt_dec_count(mntput_unheld::mnt)
        // 388 file mntput_harness.c line 841 function mntput_unheld
        CALL mntput_final_locked(mntput_unheld::mnt, mntput_unheld::shrink)
        // 389 file mntput_harness.c line 843 function mntput_unheld
        DECL mntput_unheld::$tmp::return_value_mnt_idx : signedbv[32]
        // 390 file mntput_harness.c line 843 function mntput_unheld
        CALL mntput_unheld::$tmp::return_value_mnt_idx := mnt_idx(mntput_unheld::mnt)
        // 391 file mntput_harness.c line 843 function mntput_unheld
        ASSIGN ghost_fast_final[cast(mntput_unheld::$tmp::return_value_mnt_idx, signedbv[64])] := 1
        // 392 file mntput_harness.c line 843 function mntput_unheld
        DEAD mntput_unheld::$tmp::return_value_mnt_idx
        // 393 file mntput_harness.c line 844 function mntput_unheld
        ASSERT 0 ≠ 0 // NoFastFinal (witness: this MUST fail, it shows the fast path)
        // 394 file mntput_harness.c line 845 function mntput_unheld
        SET RETURN VALUE cast(1, c_bool[8])
        // 395 file mntput_harness.c line 845 function mntput_unheld
        GOTO 2
        // 396 file mntput_harness.c line 846 function mntput_unheld
     2: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

mntput_unmounted /* mntput_unmounted */
        // 304 file mntput_harness.c line 856 function mntput_unmounted
        DECL mntput_unmounted::1::m : struct tag-mount*
        // 305 file mntput_harness.c line 857 function mntput_unmounted
        DECL mntput_unmounted::1::held : struct tag-hlist_head
        // 306 file mntput_harness.c line 857 function mntput_unmounted
        ASSIGN mntput_unmounted::1::held := { 0, { 0 }, { 0 } }
        // 307 file mntput_harness.c line 858 function mntput_unmounted
        DECL mntput_unmounted::1::shrink : struct tag-list_head
        // 308 file mntput_harness.c line 858 function mntput_unmounted
        ASSIGN mntput_unmounted::1::shrink := { 0 }
        // 309 file mntput_harness.c line 859 function mntput_unmounted
        DECL mntput_unmounted::1::k : signedbv[32]
        // 310 file mntput_harness.c line 859 function mntput_unmounted
        DECL mntput_unmounted::1::i : signedbv[32]
        // 311 file mntput_harness.c line 861 function mntput_unmounted
        CALL lock_mount_hash()
        // 312 file mntput_harness.c line 862 function mntput_unmounted
        FENCE WW RR RW WR
        // 313 file mntput_harness.c line 864 function mntput_unmounted
        ASSIGN mntput_unmounted::1::k := *mntput_unmounted::head.n - 1
        // 314 file mntput_harness.c line 864 function mntput_unmounted
     1: IF ¬(mntput_unmounted::1::k ≥ 0) THEN GOTO 4
        // 315 file mntput_harness.c line 865 function mntput_unmounted
        ASSIGN mntput_unmounted::1::i := *mntput_unmounted::head.order[cast(mntput_unmounted::1::k, signedbv[64])]
        // 316 file mntput_harness.c line 866 function mntput_unmounted
        IF ¬(*mntput_unmounted::head.on[cast(mntput_unmounted::1::i, signedbv[64])] ≠ 0) THEN GOTO 3
        // 317 file mntput_harness.c line 867 function mntput_unmounted
        SKIP
        // 318 file mntput_harness.c line 867 function mntput_unmounted
        SKIP
        // 319 file mntput_harness.c line 868 function mntput_unmounted
        ASSIGN mntput_unmounted::1::m := address_of(mounts[cast(mntput_unmounted::1::i, signedbv[64])])
        // 320 file mntput_harness.c line 869 function mntput_unmounted
        DECL mntput_unmounted::$tmp::return_value_mntput_unheld : c_bool[8]
        // 321 file mntput_harness.c line 869 function mntput_unmounted
        CALL mntput_unmounted::$tmp::return_value_mntput_unheld := mntput_unheld(mntput_unmounted::1::m, address_of(mntput_unmounted::1::shrink))
        // 322 file mntput_harness.c line 869 function mntput_unmounted
        IF ¬(mntput_unmounted::$tmp::return_value_mntput_unheld ≠ 0) THEN GOTO 2
        // 323 file mntput_harness.c line 869 function mntput_unmounted
        DEAD mntput_unmounted::$tmp::return_value_mntput_unheld
        // 324 file mntput_harness.c line 870 function mntput_unmounted
        GOTO 3
        // 325 file mntput_harness.c line 869 function mntput_unmounted
     2: DEAD mntput_unmounted::$tmp::return_value_mntput_unheld
        // 326 file mntput_harness.c line 871 function mntput_unmounted
        ASSIGN *mntput_unmounted::head.on[cast(mntput_unmounted::1::i, signedbv[64])] := 0
        // 327 file mntput_harness.c line 872 function mntput_unmounted
        ASSIGN mntput_unmounted::1::held.on[cast(mntput_unmounted::1::i, signedbv[64])] := 1
        // 328 file mntput_harness.c line 864 function mntput_unmounted
     3: ASSIGN mntput_unmounted::1::k := mntput_unmounted::1::k - 1
        // 329 file mntput_harness.c line 864 function mntput_unmounted
        GOTO 1
        // 330 file mntput_harness.c line 864 function mntput_unmounted
     4: SKIP
        // 331 file mntput_harness.c line 874 function mntput_unmounted
        CALL unlock_mount_hash()
        // 332 file mntput_harness.c line 875 function mntput_unmounted
        CALL shrink_dentry_list(address_of(mntput_unmounted::1::shrink))
        // 333 file mntput_harness.c line 878 function mntput_unmounted
        ASSIGN mntput_unmounted::1::k := *mntput_unmounted::head.n - 1
        // 334 file mntput_harness.c line 878 function mntput_unmounted
     5: IF ¬(mntput_unmounted::1::k ≥ 0) THEN GOTO 7
        // 335 file mntput_harness.c line 879 function mntput_unmounted
        ASSIGN mntput_unmounted::1::i := *mntput_unmounted::head.order[cast(mntput_unmounted::1::k, signedbv[64])]
        // 336 file mntput_harness.c line 880 function mntput_unmounted
        IF ¬(*mntput_unmounted::head.on[cast(mntput_unmounted::1::i, signedbv[64])] ≠ 0) THEN GOTO 6
        // 337 file mntput_harness.c line 881 function mntput_unmounted
        SKIP
        // 338 file mntput_harness.c line 881 function mntput_unmounted
        SKIP
        // 339 file mntput_harness.c line 882 function mntput_unmounted
        ASSIGN mntput_unmounted::1::m := address_of(mounts[cast(mntput_unmounted::1::i, signedbv[64])])
        // 340 file mntput_harness.c line 883 function mntput_unmounted
        ASSIGN *mntput_unmounted::head.on[cast(mntput_unmounted::1::i, signedbv[64])] := 0
        // 341 file mntput_harness.c line 884 function mntput_unmounted
        CALL mntput_queue_cleanup(mntput_unmounted::1::m)
        // 342 file mntput_harness.c line 878 function mntput_unmounted
     6: ASSIGN mntput_unmounted::1::k := mntput_unmounted::1::k - 1
        // 343 file mntput_harness.c line 878 function mntput_unmounted
        GOTO 5
        // 344 file mntput_harness.c line 878 function mntput_unmounted
     7: SKIP
        // 345 file mntput_harness.c line 887 function mntput_unmounted
        DECL mntput_unmounted::$tmp::return_value_hlist_empty : signedbv[32]
        // 346 file mntput_harness.c line 887 function mntput_unmounted
        CALL mntput_unmounted::$tmp::return_value_hlist_empty := hlist_empty(address_of(mntput_unmounted::1::held))
        // 347 file mntput_harness.c line 887 function mntput_unmounted
        IF ¬(mntput_unmounted::$tmp::return_value_hlist_empty ≠ 0) THEN GOTO 8
        // 348 file mntput_harness.c line 887 function mntput_unmounted
        DEAD mntput_unmounted::$tmp::return_value_hlist_empty
        // 349 file mntput_harness.c line 888 function mntput_unmounted
        DEAD mntput_unmounted::1::i
        // 350 file mntput_harness.c line 888 function mntput_unmounted
        DEAD mntput_unmounted::1::k
        // 351 file mntput_harness.c line 888 function mntput_unmounted
        DEAD mntput_unmounted::1::shrink
        // 352 file mntput_harness.c line 888 function mntput_unmounted
        DEAD mntput_unmounted::1::held
        // 353 file mntput_harness.c line 888 function mntput_unmounted
        DEAD mntput_unmounted::1::m
        // 354 file mntput_harness.c line 888 function mntput_unmounted
        GOTO 12
        // 355 file mntput_harness.c line 887 function mntput_unmounted
     8: DEAD mntput_unmounted::$tmp::return_value_hlist_empty
        // 356 file mntput_harness.c line 891 function mntput_unmounted
        CALL synchronize_rcu_expedited()
        // 357 file mntput_harness.c line 894 function mntput_unmounted
        ASSIGN mntput_unmounted::1::k := 0
        // 358 file mntput_harness.c line 894 function mntput_unmounted
     9: IF ¬(mntput_unmounted::1::k < *mntput_unmounted::head.n) THEN GOTO 11
        // 359 file mntput_harness.c line 895 function mntput_unmounted
        ASSIGN mntput_unmounted::1::i := *mntput_unmounted::head.order[cast(mntput_unmounted::1::k, signedbv[64])]
        // 360 file mntput_harness.c line 896 function mntput_unmounted
        IF ¬(mntput_unmounted::1::held.on[cast(mntput_unmounted::1::i, signedbv[64])] ≠ 0) THEN GOTO 10
        // 361 file mntput_harness.c line 897 function mntput_unmounted
        SKIP
        // 362 file mntput_harness.c line 897 function mntput_unmounted
        SKIP
        // 363 file mntput_harness.c line 898 function mntput_unmounted
        ASSIGN mntput_unmounted::1::m := address_of(mounts[cast(mntput_unmounted::1::i, signedbv[64])])
        // 364 file mntput_harness.c line 899 function mntput_unmounted
        ASSIGN mntput_unmounted::1::held.on[cast(mntput_unmounted::1::i, signedbv[64])] := 0
        // 365 file mntput_harness.c line 900 function mntput_unmounted
        CALL mntput(address_of(*mntput_unmounted::1::m.mnt))
        // 366 file mntput_harness.c line 894 function mntput_unmounted
    10: ASSIGN mntput_unmounted::1::k := mntput_unmounted::1::k + 1
        // 367 file mntput_harness.c line 894 function mntput_unmounted
        GOTO 9
        // 368 file mntput_harness.c line 894 function mntput_unmounted
    11: SKIP
        // 369 file mntput_harness.c line 902 function mntput_unmounted
        DEAD mntput_unmounted::1::i
        // 370 file mntput_harness.c line 902 function mntput_unmounted
        DEAD mntput_unmounted::1::k
        // 371 file mntput_harness.c line 902 function mntput_unmounted
        DEAD mntput_unmounted::1::shrink
        // 372 file mntput_harness.c line 902 function mntput_unmounted
        DEAD mntput_unmounted::1::held
        // 373 file mntput_harness.c line 902 function mntput_unmounted
        DEAD mntput_unmounted::1::m
        // 374 file mntput_harness.c line 902 function mntput_unmounted
    12: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

namespace_lock /* namespace_lock */
        // 670 file mntput_harness.c line 389 function namespace_lock
        SKIP
        // 671 file mntput_harness.c line 389 function namespace_lock
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

namespace_sem_up /* namespace_sem_up */
        // 668 file mntput_harness.c line 390 function namespace_sem_up
        SKIP
        // 669 file mntput_harness.c line 390 function namespace_sem_up
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

namespace_unlock /* namespace_unlock */
        // 209 file mntput_harness.c line 1020 function namespace_unlock
        DECL namespace_unlock::1::head : struct tag-hlist_head
        // 210 file mntput_harness.c line 1022 function namespace_unlock
        CALL hlist_move_list(address_of(unmounted), address_of(namespace_unlock::1::head))
        // 211 file mntput_harness.c line 1024 function namespace_unlock
        CALL namespace_sem_up()
        // 212 file mntput_harness.c line 1026 function namespace_unlock
        DECL namespace_unlock::$tmp::return_value_hlist_empty : signedbv[32]
        // 213 file mntput_harness.c line 1026 function namespace_unlock
        CALL namespace_unlock::$tmp::return_value_hlist_empty := hlist_empty(address_of(namespace_unlock::1::head))
        // 214 file mntput_harness.c line 1026 function namespace_unlock
        IF ¬(namespace_unlock::$tmp::return_value_hlist_empty ≠ 0) THEN GOTO 1
        // 215 file mntput_harness.c line 1026 function namespace_unlock
        DEAD namespace_unlock::$tmp::return_value_hlist_empty
        // 216 file mntput_harness.c line 1027 function namespace_unlock
        DEAD namespace_unlock::1::head
        // 217 file mntput_harness.c line 1027 function namespace_unlock
        GOTO 2
        // 218 file mntput_harness.c line 1026 function namespace_unlock
     1: DEAD namespace_unlock::$tmp::return_value_hlist_empty
        // 219 file mntput_harness.c line 1029 function namespace_unlock
        CALL mntput_unmounted(address_of(namespace_unlock::1::head))
        // 220 file mntput_harness.c line 1030 function namespace_unlock
        DEAD namespace_unlock::1::head
        // 221 file mntput_harness.c line 1030 function namespace_unlock
     2: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

nondet_cpu /* nondet_cpu */
        // 688 file mntput_harness.c line 121 function nondet_cpu
        DECL nondet_cpu::1::cpu : signedbv[32]
        // 689 file mntput_harness.c line 121 function nondet_cpu
        DECL nondet_cpu::$tmp::return_value_nondet_int : signedbv[32]
        // 690 file mntput_harness.c line 121 function nondet_cpu
        ASSIGN nondet_cpu::$tmp::return_value_nondet_int := side_effect statement="nondet" #identifier="nondet_int" is_nondet_nullable="1"
        // 691 file mntput_harness.c line 121 function nondet_cpu
        ASSIGN nondet_cpu::1::cpu := nondet_cpu::$tmp::return_value_nondet_int
        // 692 file mntput_harness.c line 121 function nondet_cpu
        DEAD nondet_cpu::$tmp::return_value_nondet_int
        // 693 file mntput_harness.c line 122 function nondet_cpu
        ASSUME nondet_cpu::1::cpu ≥ 0 ∧ nondet_cpu::1::cpu < 2
        // 694 file mntput_harness.c line 123 function nondet_cpu
        SET RETURN VALUE nondet_cpu::1::cpu
        // 695 file mntput_harness.c line 123 function nondet_cpu
        DEAD nondet_cpu::1::cpu
        // 696 file mntput_harness.c line 123 function nondet_cpu
        GOTO 1
        // 697 file mntput_harness.c line 124 function nondet_cpu
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

percpu_add /* percpu_add */
        // 616 file mntput_harness.c line 285 function percpu_add
        DECL percpu_add::1::cpu : signedbv[32]
        // 617 file mntput_harness.c line 285 function percpu_add
        DECL percpu_add::$tmp::return_value_nondet_cpu : signedbv[32]
        // 618 file mntput_harness.c line 285 function percpu_add
        CALL percpu_add::$tmp::return_value_nondet_cpu := nondet_cpu()
        // 619 file mntput_harness.c line 285 function percpu_add
        ASSIGN percpu_add::1::cpu := percpu_add::$tmp::return_value_nondet_cpu
        // 620 file mntput_harness.c line 285 function percpu_add
        DEAD percpu_add::$tmp::return_value_nondet_cpu
        // 621 file mntput_harness.c line 286 function percpu_add
        DECL percpu_add::1::idx : signedbv[32]
        // 622 file mntput_harness.c line 286 function percpu_add
        DECL percpu_add::$tmp::return_value_mnt_idx : signedbv[32]
        // 623 file mntput_harness.c line 286 function percpu_add
        CALL percpu_add::$tmp::return_value_mnt_idx := mnt_idx(percpu_add::mnt)
        // 624 file mntput_harness.c line 286 function percpu_add
        ASSIGN percpu_add::1::idx := percpu_add::$tmp::return_value_mnt_idx
        // 625 file mntput_harness.c line 286 function percpu_add
        DEAD percpu_add::$tmp::return_value_mnt_idx
        // 626 file mntput_harness.c line 287 function percpu_add
        DECL percpu_add::1::c : signedbv[32]
        // 627 file mntput_harness.c line 289 function percpu_add
        DECL percpu_add::$tmp::return_value_mnt_idx$0 : signedbv[32]
        // 628 file mntput_harness.c line 289 function percpu_add
        CALL percpu_add::$tmp::return_value_mnt_idx$0 := mnt_idx(percpu_add::mnt)
        // 629 file mntput_harness.c line 289 function percpu_add
        ASSERT ¬(ghost_freed[cast(percpu_add::$tmp::return_value_mnt_idx$0, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 630 file mntput_harness.c line 289 function percpu_add
        DEAD percpu_add::$tmp::return_value_mnt_idx$0
        // 631 file mntput_harness.c line 290 function percpu_add
        ATOMIC_BEGIN
        // 632 file mntput_harness.c line 291 function percpu_add
        IF ¬(percpu_add::ghost_delta < 0) THEN GOTO 1
        // 633 file mntput_harness.c line 292 function percpu_add
        ASSIGN ghost_refs[cast(tid, signedbv[64])][cast(percpu_add::1::idx, signedbv[64])] := ghost_refs[cast(tid, signedbv[64])][cast(percpu_add::1::idx, signedbv[64])] + percpu_add::ghost_delta
        // 634 file mntput_harness.c line 292 function percpu_add
     1: SKIP
        // 635 file mntput_harness.c line 294 function percpu_add
        ASSIGN percpu_add::1::c := 0
        // 636 file mntput_harness.c line 294 function percpu_add
     2: IF ¬(percpu_add::1::c < 2) THEN GOTO 6
        // 637 file mntput_harness.c line 295 function percpu_add
        IF percpu_add::1::c ≠ percpu_add::1::cpu THEN GOTO 5
        // 638 file mntput_harness.c line 296 function percpu_add
        SKIP
        // 639 file mntput_harness.c line 296 function percpu_add
        SKIP
        // 640 file mntput_harness.c line 300 function percpu_add
        IF ¬(percpu_add::is_puts ≠ 0) THEN GOTO 3
        // 641 file mntput_harness.c line 301 function percpu_add
        ASSIGN *percpu_add::mnt.mnt_pcp[cast(percpu_add::1::c, signedbv[64])].mnt_puts := *percpu_add::mnt.mnt_pcp[cast(percpu_add::1::c, signedbv[64])].mnt_puts + cast(percpu_add::cnt_delta, unsignedbv[32])
        // 642 file mntput_harness.c line 301 function percpu_add
        GOTO 4
        // 643 file mntput_harness.c line 303 function percpu_add
     3: ASSIGN *percpu_add::mnt.mnt_pcp[cast(percpu_add::1::c, signedbv[64])].mnt_gets := *percpu_add::mnt.mnt_pcp[cast(percpu_add::1::c, signedbv[64])].mnt_gets + cast(percpu_add::cnt_delta, unsignedbv[32])
        // 644 file mntput_harness.c line 303 function percpu_add
     4: SKIP
        // 645 file mntput_harness.c line 294 function percpu_add
     5: ASSIGN percpu_add::1::c := percpu_add::1::c + 1
        // 646 file mntput_harness.c line 294 function percpu_add
        GOTO 2
        // 647 file mntput_harness.c line 294 function percpu_add
     6: SKIP
        // 648 file mntput_harness.c line 306 function percpu_add
        IF ¬(percpu_add::ghost_delta > 0) THEN GOTO 7
        // 649 file mntput_harness.c line 307 function percpu_add
        ASSIGN ghost_refs[cast(tid, signedbv[64])][cast(percpu_add::1::idx, signedbv[64])] := ghost_refs[cast(tid, signedbv[64])][cast(percpu_add::1::idx, signedbv[64])] + percpu_add::ghost_delta
        // 650 file mntput_harness.c line 309 function percpu_add
        ASSERT ¬(bitand(*percpu_add::mnt.mnt.mnt_flags, 16777216) ≠ 0) ∨ ghost_transient[cast(tid, signedbv[64])] ≠ 0 // DoomedIsLast: a non-transient get on a doomed mount
        // 651 file mntput_harness.c line 311 function percpu_add
     7: SKIP
        // 652 file mntput_harness.c line 312 function percpu_add
        ATOMIC_END
        // 653 file mntput_harness.c line 313 function percpu_add
        DEAD percpu_add::1::c
        // 654 file mntput_harness.c line 313 function percpu_add
        DEAD percpu_add::1::idx
        // 655 file mntput_harness.c line 313 function percpu_add
        DEAD percpu_add::1::cpu
        // 656 file mntput_harness.c line 313 function percpu_add
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

propagate_mount_busy /* propagate_mount_busy */
        // 222 file mntput_harness.c line 1012 function propagate_mount_busy
        DECL propagate_mount_busy::$tmp::tmp_if_expr : 𝔹
        // 223 file mntput_harness.c line 1012 function propagate_mount_busy
        IF ¬(*propagate_mount_busy::mnt.nr_children ≠ 0) THEN GOTO 1
        // 224 file mntput_harness.c line 1012 function propagate_mount_busy
        ASSIGN propagate_mount_busy::$tmp::tmp_if_expr := true
        // 225 file mntput_harness.c line 1012 function propagate_mount_busy
        GOTO 2
        // 226 file mntput_harness.c line 1012 function propagate_mount_busy
     1: DECL propagate_mount_busy::$tmp::return_value_do_refcount_check : signedbv[32]
        // 227 file mntput_harness.c line 1012 function propagate_mount_busy
        CALL propagate_mount_busy::$tmp::return_value_do_refcount_check := do_refcount_check(propagate_mount_busy::mnt, propagate_mount_busy::refcnt)
        // 228 file mntput_harness.c line 1012 function propagate_mount_busy
        ASSIGN propagate_mount_busy::$tmp::tmp_if_expr := (propagate_mount_busy::$tmp::return_value_do_refcount_check ≠ 0 ? true : false)
        // 229 file mntput_harness.c line 1012 function propagate_mount_busy
     2: SKIP
        // 230 file mntput_harness.c line 1012 function propagate_mount_busy
        DEAD propagate_mount_busy::$tmp::return_value_do_refcount_check
        // 231 file mntput_harness.c line 1012 function propagate_mount_busy
        IF ¬propagate_mount_busy::$tmp::tmp_if_expr THEN GOTO 3
        // 232 file mntput_harness.c line 1012 function propagate_mount_busy
        DEAD propagate_mount_busy::$tmp::tmp_if_expr
        // 233 file mntput_harness.c line 1013 function propagate_mount_busy
        SET RETURN VALUE 1
        // 234 file mntput_harness.c line 1013 function propagate_mount_busy
        GOTO 4
        // 235 file mntput_harness.c line 1012 function propagate_mount_busy
     3: DEAD propagate_mount_busy::$tmp::tmp_if_expr
        // 236 file mntput_harness.c line 1014 function propagate_mount_busy
        SET RETURN VALUE 0
        // 237 file mntput_harness.c line 1014 function propagate_mount_busy
        GOTO 4
        // 238 file mntput_harness.c line 1015 function propagate_mount_busy
     4: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

read_seqbegin /* read_seqbegin */
        // 698 file mntput_harness.c line 364 function read_seqbegin
        DECL read_seqbegin::1::ret : unsignedbv[32]
        // 699 file mntput_harness.c line 364 function read_seqbegin
        ASSIGN read_seqbegin::1::ret := *read_seqbegin::sl.sequence
        // 700 file mntput_harness.c line 365 function read_seqbegin
        ASSUME ¬(bitand(read_seqbegin::1::ret, cast(1, unsignedbv[32])) ≠ 0)
        // 701 file mntput_harness.c line 366 function read_seqbegin
        FENCE RR
        // 702 file mntput_harness.c line 367 function read_seqbegin
        SET RETURN VALUE read_seqbegin::1::ret
        // 703 file mntput_harness.c line 367 function read_seqbegin
        DEAD read_seqbegin::1::ret
        // 704 file mntput_harness.c line 367 function read_seqbegin
        GOTO 1
        // 705 file mntput_harness.c line 368 function read_seqbegin
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

read_seqretry /* read_seqretry */
        // 684 file mntput_harness.c line 372 function read_seqretry
        FENCE RR
        // 685 file mntput_harness.c line 373 function read_seqretry
        SET RETURN VALUE cast(*read_seqretry::sl.sequence ≠ read_seqretry::start, unsignedbv[32])
        // 686 file mntput_harness.c line 373 function read_seqretry
        GOTO 1
        // 687 file mntput_harness.c line 374 function read_seqretry
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

real_mount /* real_mount */
        // 805 file mntput_harness.c line 218 function real_mount
        SET RETURN VALUE cast(cast(real_mount::mnt, signedbv[8]*) - cast(16, signedbv[64]), struct tag-mount*)
        // 806 file mntput_harness.c line 218 function real_mount
        GOTO 1
        // 807 file mntput_harness.c line 219 function real_mount
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

run_task_work /* run_task_work */
        // 810 file mntput_harness.c line 463 function run_task_work
        DECL run_task_work::1::i : signedbv[32]
        // 811 file mntput_harness.c line 464 function run_task_work
        ASSIGN run_task_work::1::i := 0
        // 812 file mntput_harness.c line 464 function run_task_work
     1: IF ¬(run_task_work::1::i < 1) THEN GOTO 3
        // 813 file mntput_harness.c line 465 function run_task_work
        IF ¬(task_work_pending[cast(run_task_work::1::i, signedbv[64])] ≠ 0) THEN GOTO 2
        // 814 file mntput_harness.c line 466 function run_task_work
        ASSIGN task_work_pending[cast(run_task_work::1::i, signedbv[64])] := 0
        // 815 file mntput_harness.c line 467 function run_task_work
        CALL __cleanup_mnt(address_of(mounts[cast(run_task_work::1::i, signedbv[64])].mnt_rcu))
        // 816 file mntput_harness.c line 468 function run_task_work
     2: SKIP
        // 817 file mntput_harness.c line 464 function run_task_work
        ASSIGN run_task_work::1::i := run_task_work::1::i + 1
        // 818 file mntput_harness.c line 464 function run_task_work
        GOTO 1
        // 819 file mntput_harness.c line 464 function run_task_work
     3: SKIP
        // 820 file mntput_harness.c line 470 function run_task_work
        DEAD run_task_work::1::i
        // 821 file mntput_harness.c line 470 function run_task_work
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

security_sb_umount /* security_sb_umount */
        // 598 file mntput_harness.c line 498 function security_sb_umount
        DECL security_sb_umount::$tmp::return_value_nondet_bool : c_bool[8]
        // 599 file mntput_harness.c line 498 function security_sb_umount
        ASSIGN security_sb_umount::$tmp::return_value_nondet_bool := cast(side_effect statement="nondet" #identifier="nondet_bool" is_nondet_nullable="1", c_bool[8])
        // 600 file mntput_harness.c line 498 function security_sb_umount
        SET RETURN VALUE (security_sb_umount::$tmp::return_value_nondet_bool ≠ 0 ? 0 : -1)
        // 601 file mntput_harness.c line 498 function security_sb_umount
        DEAD security_sb_umount::$tmp::return_value_nondet_bool
        // 602 file mntput_harness.c line 498 function security_sb_umount
        GOTO 1
        // 603 file mntput_harness.c line 499 function security_sb_umount
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

shrink_dentry_list /* shrink_dentry_list */
        // 902 file mntput_harness.c line 493 function shrink_dentry_list
        SKIP
        // 903 file mntput_harness.c line 493 function shrink_dentry_list
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

shrink_submounts /* shrink_submounts */
        // 793 file mntput_harness.c line 494 function shrink_submounts
        SKIP
        // 794 file mntput_harness.c line 494 function shrink_submounts
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

synchronize_rcu_expedited /* synchronize_rcu_expedited */
        // 659 file mntput_harness.c line 424 function synchronize_rcu_expedited
        ASSIGN ghost_gps := ghost_gps + 1
        // 660 file mntput_harness.c line 425 function synchronize_rcu_expedited
        CALL __synchronize_rcu()
        // 661 file mntput_harness.c line 426 function synchronize_rcu_expedited
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

task_work_add /* task_work_add */
        // 604 file mntput_harness.c line 453 function task_work_add
        DECL task_work_add::1::idx : signedbv[32]
        // 605 file mntput_harness.c line 453 function task_work_add
        DECL task_work_add::$tmp::return_value_mnt_idx : signedbv[32]
        // 606 file mntput_harness.c line 453 function task_work_add
        CALL task_work_add::$tmp::return_value_mnt_idx := mnt_idx(cast(cast(task_work_add::twork, signedbv[8]*) - cast(40, signedbv[64]), struct tag-mount*))
        // 607 file mntput_harness.c line 453 function task_work_add
        ASSIGN task_work_add::1::idx := task_work_add::$tmp::return_value_mnt_idx
        // 608 file mntput_harness.c line 453 function task_work_add
        DEAD task_work_add::$tmp::return_value_mnt_idx
        // 609 file mntput_harness.c line 454 function task_work_add
        ASSERT task_work_add::task = address_of(tasks[cast(tid, signedbv[64])]) // TWA_RESUME on current
        // 610 file mntput_harness.c line 455 function task_work_add
        ASSERT ¬(task_work_pending[cast(task_work_add::1::idx, signedbv[64])] ≠ 0) // task_work_add(): the same mount queued twice
        // 611 file mntput_harness.c line 456 function task_work_add
        ASSIGN task_work_pending[cast(task_work_add::1::idx, signedbv[64])] := 1
        // 612 file mntput_harness.c line 457 function task_work_add
        SET RETURN VALUE 0
        // 613 file mntput_harness.c line 457 function task_work_add
        DEAD task_work_add::1::idx
        // 614 file mntput_harness.c line 457 function task_work_add
        GOTO 1
        // 615 file mntput_harness.c line 458 function task_work_add
     1: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

umount_mnt /* umount_mnt */
        // 286 file mntput_harness.c line 957 function umount_mnt
        DECL umount_mnt::$tmp::return_value_mnt_idx : signedbv[32]
        // 287 file mntput_harness.c line 957 function umount_mnt
        CALL umount_mnt::$tmp::return_value_mnt_idx := mnt_idx(umount_mnt::mnt)
        // 288 file mntput_harness.c line 957 function umount_mnt
        ASSIGN *umount_mnt::mnt.mnt_parent := umount_mnt::$tmp::return_value_mnt_idx
        // 289 file mntput_harness.c line 957 function umount_mnt
        DEAD umount_mnt::$tmp::return_value_mnt_idx
        // 290 file mntput_harness.c line 959 function umount_mnt
        DECL umount_mnt::$tmp::return_value_mnt_idx$0 : signedbv[32]
        // 291 file mntput_harness.c line 959 function umount_mnt
        CALL umount_mnt::$tmp::return_value_mnt_idx$0 := mnt_idx(umount_mnt::mnt)
        // 292 file mntput_harness.c line 959 function umount_mnt
        ASSIGN ghost_hashed[cast(umount_mnt::$tmp::return_value_mnt_idx$0, signedbv[64])] := 0
        // 293 file mntput_harness.c line 959 function umount_mnt
        DEAD umount_mnt::$tmp::return_value_mnt_idx$0
        // 294 file mntput_harness.c line 960 function umount_mnt
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

umount_tree /* umount_tree */
        // 239 file mntput_harness.c line 973 function umount_tree
        DECL umount_tree::1::p : struct tag-mount*
        // 240 file mntput_harness.c line 974 function umount_tree
        DECL umount_tree::1::i : signedbv[32]
        // 241 file mntput_harness.c line 976 function umount_tree
        ASSERT umount_tree::mnt = address_of(mounts[cast(0, signedbv[64])]) // the harness unmounts the tree at mounts[0]
        // 242 file mntput_harness.c line 978 function umount_tree
        ASSIGN umount_tree::1::i := 0
        // 243 file mntput_harness.c line 978 function umount_tree
     1: IF ¬(umount_tree::1::i < 1) THEN GOTO 2
        // 244 file mntput_harness.c line 979 function umount_tree
        ASSIGN umount_tree::1::p := address_of(mounts[cast(umount_tree::1::i, signedbv[64])])
        // 245 file mntput_harness.c line 981 function umount_tree
        DECL umount_tree::1::1::1::1::__c : signedbv[32]
        // 246 file mntput_harness.c line 981 function umount_tree
        ASSIGN umount_tree::1::1::1::1::__c := cast(¬(¬(bitand(*umount_tree::1::p.mnt.mnt_flags, 134217728) ≠ 0)), signedbv[32])
        // 247 file mntput_harness.c line 981 function umount_tree
        ASSERT ¬(umount_tree::1::1::1::1::__c ≠ 0) // WARN_ON(p->mnt.mnt_flags & 0x8000000)
        // 248 file mntput_harness.c line 981 function umount_tree
        EXPRESSION umount_tree::1::1::1::1::__c
        // 249 file mntput_harness.c line 981 function umount_tree
        DEAD umount_tree::1::1::1::1::__c
        // 250 file mntput_harness.c line 982 function umount_tree
        ASSIGN *umount_tree::1::p.mnt.mnt_flags := bitor(*umount_tree::1::p.mnt.mnt_flags, 134217728)
        // 251 file mntput_harness.c line 978 function umount_tree
        ASSIGN umount_tree::1::i := umount_tree::1::i + 1
        // 252 file mntput_harness.c line 978 function umount_tree
        GOTO 1
        // 253 file mntput_harness.c line 978 function umount_tree
     2: SKIP
        // 254 file mntput_harness.c line 986 function umount_tree
        ASSIGN umount_tree::1::i := 0
        // 255 file mntput_harness.c line 986 function umount_tree
     3: IF ¬(umount_tree::1::i < 1) THEN GOTO 4
        // 256 file mntput_harness.c line 987 function umount_tree
        ASSIGN mounts[cast(umount_tree::1::i, signedbv[64])].nr_children := 0
        // 257 file mntput_harness.c line 986 function umount_tree
        ASSIGN umount_tree::1::i := umount_tree::1::i + 1
        // 258 file mntput_harness.c line 986 function umount_tree
        GOTO 3
        // 259 file mntput_harness.c line 986 function umount_tree
     4: SKIP
        // 260 file mntput_harness.c line 990 function umount_tree
        ASSIGN umount_tree::1::i := 0
        // 261 file mntput_harness.c line 990 function umount_tree
     5: IF ¬(umount_tree::1::i < 1) THEN GOTO 9
        // 262 file mntput_harness.c line 991 function umount_tree
        ASSIGN umount_tree::1::p := address_of(mounts[cast(umount_tree::1::i, signedbv[64])])
        // 263 file mntput_harness.c line 992 function umount_tree
        ASSIGN *umount_tree::1::p.mnt_ns := 0
        // 264 file mntput_harness.c line 993 function umount_tree
        DECL umount_tree::$tmp::return_value_mnt_idx : signedbv[32]
        // 265 file mntput_harness.c line 993 function umount_tree
        CALL umount_tree::$tmp::return_value_mnt_idx := mnt_idx(umount_tree::1::p)
        // 266 file mntput_harness.c line 993 function umount_tree
        ASSIGN ghost_umounted[cast(umount_tree::$tmp::return_value_mnt_idx, signedbv[64])] := 1
        // 267 file mntput_harness.c line 993 function umount_tree
        DEAD umount_tree::$tmp::return_value_mnt_idx
        // 268 file mntput_harness.c line 994 function umount_tree
        IF ¬(bitand(cast(umount_tree::how, signedbv[32]), 1) ≠ 0) THEN GOTO 6
        // 269 file mntput_harness.c line 995 function umount_tree
        ASSIGN *umount_tree::1::p.mnt.mnt_flags := bitor(*umount_tree::1::p.mnt.mnt_flags, 33554432)
        // 270 file mntput_harness.c line 995 function umount_tree
     6: SKIP
        // 271 file mntput_harness.c line 997 function umount_tree
        DECL umount_tree::$tmp::return_value_mnt_has_parent : signedbv[32]
        // 272 file mntput_harness.c line 997 function umount_tree
        CALL umount_tree::$tmp::return_value_mnt_has_parent := mnt_has_parent(umount_tree::1::p)
        // 273 file mntput_harness.c line 997 function umount_tree
        IF ¬(umount_tree::$tmp::return_value_mnt_has_parent ≠ 0) THEN GOTO 7
        // 274 file mntput_harness.c line 997 function umount_tree
        DEAD umount_tree::$tmp::return_value_mnt_has_parent
        // 275 file mntput_harness.c line 998 function umount_tree
        CALL umount_mnt(umount_tree::1::p)
        // 276 file mntput_harness.c line 999 function umount_tree
        GOTO 8
        // 277 file mntput_harness.c line 997 function umount_tree
     7: DEAD umount_tree::$tmp::return_value_mnt_has_parent
        // 278 
     8: SKIP
        // 279 file mntput_harness.c line 1000 function umount_tree
        CALL unmounted_add(address_of(unmounted), umount_tree::1::p)
        // 280 file mntput_harness.c line 990 function umount_tree
        ASSIGN umount_tree::1::i := umount_tree::1::i + 1
        // 281 file mntput_harness.c line 990 function umount_tree
        GOTO 5
        // 282 file mntput_harness.c line 990 function umount_tree
     9: SKIP
        // 283 file mntput_harness.c line 1002 function umount_tree
        DEAD umount_tree::1::i
        // 284 file mntput_harness.c line 1002 function umount_tree
        DEAD umount_tree::1::p
        // 285 file mntput_harness.c line 1002 function umount_tree
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

unlock_mount_hash /* unlock_mount_hash */
        // 883 file mntput_harness.c line 385 function unlock_mount_hash
        CALL write_sequnlock(address_of(mount_lock))
        // 884 file mntput_harness.c line 386 function unlock_mount_hash
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

unmounted_add /* unmounted_add */
        // 719 file mntput_harness.c line 948 function unmounted_add
        DECL unmounted_add::1::i : signedbv[32]
        // 720 file mntput_harness.c line 948 function unmounted_add
        DECL unmounted_add::$tmp::return_value_mnt_idx : signedbv[32]
        // 721 file mntput_harness.c line 948 function unmounted_add
        CALL unmounted_add::$tmp::return_value_mnt_idx := mnt_idx(unmounted_add::p)
        // 722 file mntput_harness.c line 948 function unmounted_add
        ASSIGN unmounted_add::1::i := unmounted_add::$tmp::return_value_mnt_idx
        // 723 file mntput_harness.c line 948 function unmounted_add
        DEAD unmounted_add::$tmp::return_value_mnt_idx
        // 724 file mntput_harness.c line 949 function unmounted_add
        ASSERT ¬(*unmounted_add::h.on[cast(unmounted_add::1::i, signedbv[64])] ≠ 0) // a mount is put on the unmounted list twice
        // 725 file mntput_harness.c line 950 function unmounted_add
        DECL unmounted_add::$tmp::tmp_post : signedbv[32]
        // 726 file mntput_harness.c line 950 function unmounted_add
        ASSIGN unmounted_add::$tmp::tmp_post := *unmounted_add::h.n
        // 727 file mntput_harness.c line 950 function unmounted_add
        ASSIGN *unmounted_add::h.n := *unmounted_add::h.n + 1
        // 728 file mntput_harness.c line 950 function unmounted_add
        ASSIGN *unmounted_add::h.order[cast(unmounted_add::$tmp::tmp_post, signedbv[64])] := unmounted_add::1::i
        // 729 file mntput_harness.c line 950 function unmounted_add
        DEAD unmounted_add::$tmp::tmp_post
        // 730 file mntput_harness.c line 951 function unmounted_add
        ASSIGN *unmounted_add::h.on[cast(unmounted_add::1::i, signedbv[64])] := 1
        // 731 file mntput_harness.c line 952 function unmounted_add
        DEAD unmounted_add::1::i
        // 732 file mntput_harness.c line 952 function unmounted_add
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

walker /* walker */
        // 57 file mntput_harness.c line 1200 function walker
        DECL walker::1::idx : signedbv[32]
        // 58 file mntput_harness.c line 1200 function walker
        ASSIGN walker::1::idx := 0
        // 59 file mntput_harness.c line 1201 function walker
        DECL walker::1::m : struct tag-mount*
        // 60 file mntput_harness.c line 1201 function walker
        ASSIGN walker::1::m := address_of(mounts[cast(walker::1::idx, signedbv[64])])
        // 61 file mntput_harness.c line 1202 function walker
        DECL walker::1::seq : unsignedbv[32]
        // 62 file mntput_harness.c line 1203 function walker
        DECL walker::1::found : signedbv[32]
        // 63 file mntput_harness.c line 1205 function walker
        ASSIGN tid := 2
        // 64 file mntput_harness.c line 1206 function walker
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(1, c_bool[8])
        // 65 file mntput_harness.c line 1207 function walker
        CALL walker::1::seq := read_seqbegin(address_of(mount_lock))
        // 66 file mntput_harness.c line 1214 function walker
        ASSIGN walker::1::found := cast(ghost_hashed[cast(walker::1::idx, signedbv[64])] ≠ 0 ∨ ghost_refs[cast(1, signedbv[64])][cast(walker::1::idx, signedbv[64])] > 0, signedbv[32])
        // 67 file mntput_harness.c line 1215 function walker
        IF ¬(walker::1::found ≠ 0) THEN GOTO 2
        // 68 file mntput_harness.c line 1216 function walker
        ASSIGN ghost_transient[cast(2, signedbv[64])] := 1
        // 69 file mntput_harness.c line 1217 function walker
        DECL walker::$tmp::return_value_legitimize_mnt : c_bool[8]
        // 70 file mntput_harness.c line 1217 function walker
        CALL walker::$tmp::return_value_legitimize_mnt := legitimize_mnt(address_of(*walker::1::m.mnt), walker::1::seq)
        // 71 file mntput_harness.c line 1217 function walker
        IF ¬(walker::$tmp::return_value_legitimize_mnt ≠ 0) THEN GOTO 1
        // 72 file mntput_harness.c line 1217 function walker
        DEAD walker::$tmp::return_value_legitimize_mnt
        // 73 file mntput_harness.c line 1218 function walker
        ASSIGN ghost_transient[cast(2, signedbv[64])] := 0
        // 74 file mntput_harness.c line 1219 function walker
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 75 file mntput_harness.c line 1221 function walker
        DECL walker::$tmp::return_value_mnt_idx : signedbv[32]
        // 76 file mntput_harness.c line 1221 function walker
        CALL walker::$tmp::return_value_mnt_idx := mnt_idx(walker::1::m)
        // 77 file mntput_harness.c line 1221 function walker
        ASSERT ¬(ghost_freed[cast(walker::$tmp::return_value_mnt_idx, signedbv[64])] ≠ 0) // NoUAF: struct mount touched after it was freed
        // 78 file mntput_harness.c line 1221 function walker
        DEAD walker::$tmp::return_value_mnt_idx
        // 79 file mntput_harness.c line 1222 function walker
        ASSERT ¬(ghost_sb_torn[cast(walker::1::idx, signedbv[64])] ≠ 0) // NoUAF: a legitimized walker uses a shut-down filesystem
        // 80 file mntput_harness.c line 1223 function walker
        ASSERT ¬(bitand(*walker::1::m.mnt.mnt_flags, 16777216) ≠ 0) // DoomedIsLast: a legitimized walker holds a doomed mount
        // 81 file mntput_harness.c line 1224 function walker
        CALL mntput(address_of(*walker::1::m.mnt))
        // 82 file mntput_harness.c line 1225 function walker
        CALL run_task_work()
        // 83 file mntput_harness.c line 1226 function walker
        ASSIGN thread_done[cast(2, signedbv[64])] := cast(1, c_bool[8])
        // 84 file mntput_harness.c line 1227 function walker
        DEAD walker::1::found
        // 85 file mntput_harness.c line 1227 function walker
        DEAD walker::1::seq
        // 86 file mntput_harness.c line 1227 function walker
        DEAD walker::1::m
        // 87 file mntput_harness.c line 1227 function walker
        DEAD walker::1::idx
        // 88 file mntput_harness.c line 1227 function walker
        GOTO 3
        // 89 file mntput_harness.c line 1217 function walker
     1: DEAD walker::$tmp::return_value_legitimize_mnt
        // 90 file mntput_harness.c line 1229 function walker
        ASSIGN ghost_transient[cast(2, signedbv[64])] := 0
        // 91 file mntput_harness.c line 1230 function walker
     2: SKIP
        // 92 file mntput_harness.c line 1231 function walker
        ASSIGN in_rcu[cast(tid, signedbv[64])] := cast(0, c_bool[8])
        // 93 file mntput_harness.c line 1232 function walker
        CALL run_task_work()
        // 94 file mntput_harness.c line 1233 function walker
        ASSIGN thread_done[cast(2, signedbv[64])] := cast(1, c_bool[8])
        // 95 file mntput_harness.c line 1234 function walker
        DEAD walker::1::found
        // 96 file mntput_harness.c line 1234 function walker
        DEAD walker::1::seq
        // 97 file mntput_harness.c line 1234 function walker
        DEAD walker::1::m
        // 98 file mntput_harness.c line 1234 function walker
        DEAD walker::1::idx
        // 99 file mntput_harness.c line 1234 function walker
     3: END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

write_seqlock /* write_seqlock */
        // 711 file mntput_harness.c line 341 function write_seqlock
        ATOMIC_BEGIN
        // 712 file mntput_harness.c line 342 function write_seqlock
        ASSUME ¬(*write_seqlock::sl.locked ≠ 0)
        // 713 file mntput_harness.c line 343 function write_seqlock
        ASSIGN *write_seqlock::sl.locked := cast(1, c_bool[8])
        // 714 file mntput_harness.c line 344 function write_seqlock
        ATOMIC_END
        // 715 file mntput_harness.c line 345 function write_seqlock
        FENCE WW RR RW WR
        // 716 file mntput_harness.c line 347 function write_seqlock
        ASSIGN *write_seqlock::sl.sequence := *write_seqlock::sl.sequence + 1
        // 717 file mntput_harness.c line 348 function write_seqlock
        FENCE WW
        // 718 file mntput_harness.c line 349 function write_seqlock
        END_FUNCTION

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

write_sequnlock /* write_sequnlock */
        // 706 file mntput_harness.c line 354 function write_sequnlock
        FENCE WW
        // 707 file mntput_harness.c line 355 function write_sequnlock
        ASSIGN *write_sequnlock::sl.sequence := *write_sequnlock::sl.sequence + 1
        // 708 file mntput_harness.c line 357 function write_sequnlock
        FENCE WW
        // 709 file mntput_harness.c line 358 function write_sequnlock
        ASSIGN *write_sequnlock::sl.locked := cast(0, c_bool[8])
        // 710 file mntput_harness.c line 359 function write_sequnlock
        END_FUNCTION

