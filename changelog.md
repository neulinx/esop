
* __Add missed final state to xl_fsm.__

    [Gary Hai](gary@xl59.com) - Fri, 29 Jul 2016 11:39:37 +0800
    

* __Temporary subscription operations in FSM.__

    [Gary Hai](gary@xl59.com) - Fri, 29 Jul 2016 00:02:57 +0800
    
    

* __Fix fatal bugs and add helpers.__

    [Gary Hai](gary@xl59.com) - Thu, 28 Jul 2016 13:57:46 +0800
    
    1. exception crashed in reuse mode of xl_fsm 2. {xlx, From, Path, Command} is
    ignored by state actions. 3. Add helper APIs for subscription functions.
    

* __Change functionality of action &#39;do&#39;, gain more control of state.__

    [Gary Hai](gary@xl59.com) - Wed, 27 Jul 2016 16:42:49 +0800
    
    

* __Add fsm attribute in state of FSM.__

    [Gary Hai](gary@xl59.com) - Wed, 27 Jul 2016 11:43:53 +0800
    
    

* __Add get, put, delete, notify, unsubscribe support.__

    [Gary Hai](gary@xl59.com) - Wed, 27 Jul 2016 11:38:45 +0800
    
    

* __Add data modification methods in actor.__

    [Gary Hai](gary@xl59.com) - Tue, 26 Jul 2016 17:48:32 +0800
    
    

* __Add state subscribe support.__

    [Gary Hai](gary@xl59.com) - Tue, 26 Jul 2016 15:45:00 +0800
    
    And fix bug of wakeup process.
    

* __Unify state result__

    [Gary Hai](gary@xl59.com) - Tue, 26 Jul 2016 09:54:58 +0800
    
    Four elements tuple of result means stop.
    

* __Add merge function to chain behaviors of states.__

    [Gary Hai](gary@xl59.com) - Sun, 24 Jul 2016 12:34:25 +0800
    
    

* __Always call state leave function even if engine mode is reuse.__

    [Gary Hai](gary@xl59.com) - Sat, 23 Jul 2016 23:41:17 +0800
    
    And do not reply when exception in react.
    

* __Reply the caller even it crash the FSM.__

    [Gary Hai](gary@xl59.com) - Sat, 23 Jul 2016 03:04:06 +0800
    
    

* __Make result value more elegant.__

    [Gary Hai](gary@xl59.com) - Sat, 23 Jul 2016 02:56:14 +0800
    
    

* __Fix bug of linked process in state may crash FSM when in reuse mode.__

    [Gary Hai](gary@xl59.com) - Fri, 22 Jul 2016 20:20:17 +0800
    
    Sadly, process links mechanism of OTP is broken.
    

* __React of state can cancel stop or hibernate command.__

    [garyhai](gary@XL59.com) - Fri, 22 Jul 2016 20:02:56 +0800
    
    

* __Make message handler more readable.__

    [garyhai](gary@XL59.com) - Fri, 22 Jul 2016 18:37:47 +0800
    
    
    

* __Fix issue: state entry failure when  xl_fsm in reuse mode.__

    [garyhai](gary@XL59.com) - Thu, 21 Jul 2016 13:11:14 +0800
    
    

* __Add payload as input/output to implement Mealy FSM.__

    [garyhai](gary@XL59.com) - Wed, 20 Jul 2016 20:27:52 +0800
    
    And, 1. redefined activity &#39;do&#39; dones not directly effect state 2. fire
    xlx_wakeup when resume from detached state.
    

* __Add function specification for all exported functions.__

    [garyhai](gary@XL59.com) - Tue, 19 Jul 2016 14:47:43 +0800
    
    

* __Seperate parent to realm and actor.__

    [garyhai](gary@XL59.com) - Tue, 19 Jul 2016 13:43:41 +0800
    
    

* __Re-support engine mode in FSM, and more ...__

    [garyhai](gary@XL59.com) - Tue, 19 Jul 2016 12:06:48 +0800
    
    1. Rollback rebar3 from v3.2 to v3.1, because  xl_fsm_test has no coverage
    data. 2. Change company name. 3. Export more functions in xl_state.
    

* __Change default Timeout paramenter of xl_state:call to infinity.__

    [garyhai](gary@XL59.com) - Mon, 18 Jul 2016 15:45:02 +0800
    
    
    

