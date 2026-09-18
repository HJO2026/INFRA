package bench.stub;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** 파이프라인 검증용 스텁. 실제 구현이 아니다. */
@SpringBootApplication
public class StubApplication {
    public static void main(String[] args) {
        SpringApplication.run(StubApplication.class, args);
    }
}
