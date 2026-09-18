package bench.stub;

import java.util.Map;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class StubController {
    private final JdbcTemplate jdbc;

    public StubController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** DB 를 건드리지 않는 경로. 앱·네트워크 오버헤드 기준선. */
    @GetMapping("/ping")
    public Map<String, String> ping() {
        return Map.of("status", "ok");
    }

    /** DB 왕복 1회. 커넥션 풀·드라이버 경로 검증. */
    @GetMapping("/db")
    public Map<String, Object> db() {
        Long count = jdbc.queryForObject("SELECT count(*) FROM stub_ping", Long.class);
        return Map.of("status", "ok", "rows", count == null ? 0L : count);
    }
}
