from kirtan_backend.server import should_log_request_method


def test_telemetry_polling_methods_do_not_spam_persistent_log():
    assert should_log_request_method("runtime_stats") is False
    assert should_log_request_method("model_cache") is False
    assert should_log_request_method("ping") is False


def test_action_methods_still_write_to_persistent_log():
    assert should_log_request_method("separate") is True
    assert should_log_request_method("delete_model_cache_item") is True
    assert should_log_request_method("cancel") is True
