FROM maven:3.5-jdk-8 as BUILD
  
COPY src /usr/src/sji/src
COPY pom.xml /usr/src/sji
RUN mvn -f /usr/src/sji/pom.xml clean package

FROM openjdk:8-jdk-alpine
WORKDIR /

COPY --from=build /usr/src/sji/target/javasqlinjection.war /

EXPOSE 80

ENTRYPOINT ["sh","-c","java -jar /javasqlinjection.war"]